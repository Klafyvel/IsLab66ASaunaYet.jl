module IsLab66ASaunaYet

using Telegram, Telegram.API
using Dates
using Arrow, DataFrames
using ArgParse
using BaseDirs
using CairoMakie
using HidApi
using Preferences


"""
processvalue(process)

Read a process value and return the latest value.

Seel also [`processtype`](@ref).
"""
function processvalue end
"""
processtype(process)::T
processtype(::Type{process})::T

Return the value type returned by the process.

Seel also [`processvalue`](@ref).
"""
function processtype end
processtype(::T) where T = processtype(T)

struct ProcessDummy 
end
processvalue(::ProcessDummy) = randn()
processtype(::Type{ProcessDummy}) = Float64

struct TEMPer end
# For linux we need to remove the first element apparently?? This may be a bug in hidapi 1.14
@static if Sys.iswindows()
	const FIRMWARE_REQUEST = [0x00, 0x01, 0x86, 0xff, 0x01, 0x00, 0x00, 0x00, 0x00]
	const DATA_REQUEST = [0x00, 0x01, 0x80, 0x33, 0x01, 0x00, 0x00, 0x00, 0x00]
else
	const FIRMWARE_REQUEST = [0x01, 0x86, 0xff, 0x01, 0x00, 0x00, 0x00, 0x00]
	const DATA_REQUEST = [0x01, 0x80, 0x33, 0x01, 0x00, 0x00, 0x00, 0x00]
end
# TODO: if in the future I need to handle sensor variations..
# hastemperature(t::TEMPer) = true
# hashumidity(t::TEMPer) = false
# hasinternal(t::TEMPer) = false
# hasexternal(t::TEMPer) = true

processtype(::Type{TEMPer}) = Float64
function processvalue(t::TEMPer)
    init()
    dev = _find_sensor()
    isnothing(dev) && return 0.0
    @debug "Reading from device" dev
    open(dev)
    handle = dev.handle
    HidApi.write(dev, DATA_REQUEST)
    sleep(0.5)
    data = read(dev)
    Base.close(dev)
    shutdown()
    return reinterpret(UInt16, data[2:3])[1]/100.0
end

function _get_firmware(dev)
    try
        open(dev)
        handle = dev.handle
        write(dev, FIRMWARE_REQUEST)
        result = Cuchar[]
        data = Vector{Cuchar}(undef, 8)
        while true
            val = HidApi.hid_read_timeout(handle, data, 8, 200)
            if val == -1 
                error("error while reading")
            elseif val == 0
		@debug "Timeouted."
                break
            end
            append!(result, data)
        end
        Base.close(dev)
        result = String(result)
	@debug "Read firmware $(repr(result))"
        return result
    catch e 
        @debug "Error while opening thermometer candidate." e
        return ""
    end
end

function _is_valid_sensor_from_usb(dev)
    all([
        dev.manufacturer_string == "PCsensor"
        dev.product_string == "TEMPer1F"
        dev.product_id == 0xa001
        dev.vendor_id == 0x3553
        # dev.usage == 0x0000
    ])
end

function _find_sensor()
    valid_from_usb = filter(_is_valid_sensor_from_usb, enumerate_devices())
    @debug "Found valid usb" valid_from_usb
    respond_with_firmware = filter((!isempty)∘_get_firmware, valid_from_usb)
    if length(respond_with_firmware) > 1
        @warn "More than one thermometer found. Using the first one." respond_with_firmware
    elseif isempty(respond_with_firmware)
        @warn "No thermometer found."
        return nothing
    end
    return first(respond_with_firmware)
end

const PROJECT = BaseDirs.Project("IsLab66ASaunaYet", org="Unifi-CNR")

mutable struct Bot
    client::TelegramClient
    process
    storage
    lastread
    exit
    commandparsesettings
    known_chat_id
    lastalert
    lastalertdate
end

function Bot(process; storage=BaseDirs.User.data(PROJECT, "temperature_data.arrow"))
    client = TelegramClient(token())
    if !isfile(storage)
        mkpath(dirname(storage))
        Arrow.write(storage, (time=DateTime[], temperature=Vector{processtype(process)}()); file=false)
    end
    settings = ArgParseSettings(commands_are_required=true,
                                add_help=false,
                                usage="""
                                * Show this help: /help
                                * Get current temperature: /temp
                                * Get temperature profile for the 31ˢᵗ of October 2024: /temp 2024-10-31
                                * Get temperature profile from the 31ˢᵗ of October 19:30 to the 3ʳᵈ of November 18:15 : /temp 2024-10-31T19:30 2024-11-3T:18-15
    """)
    @add_arg_table! settings begin
        "help"
        help = "Show help."
        action = :command
        "temp"
        help = "Get temperature. If no date set, read the current temperature."
        action = :command
        "set"
        help = "Change bot settings. If no option given, show the current settings."
        action = :command
    end
    @add_arg_table! settings["temp"] begin
        "date1"
        help = "Optional first date, if date2 is not set, display the temperature profile of a day."
        required = false
        arg_type = DateTime
        "date2"
        help = "Optional second date, if set, display the temperature profile from date1 to date2."
        required = false
        arg_type = DateTime
    end
    @add_arg_table! settings["set"] begin
        "--poll-period"
        help = "poll time (in minutes) for the temperature."
        arg_type = Dates.Minute
        "--lower-bound"
        help = "Lower bound of the temperature. Readings below trigger an alert."
        arg_type = Float64
        "--higher-bound"
        help = "Higher bound of the temperature. Readings above trigger an alert."
        arg_type = Float64
        "--alert-period"
        help = "Minimum time between two alerts of the same kind."
        arg_type = Dates.Minute
    end
    bot = Bot(client, process, storage, now(), false, settings, Set{String}(), nothing, now()-alertperiod())
    bot.commandparsesettings.exc_handler = make_exc_handler(bot)
    bot
end

pollperiod() = @load_preference("pollperiod", Dates.Minute(1))
pollperiod!(v) = @set_preferences!("pollperiod"=>v)
alertperiod() = @load_preference("alertperiod", Dates.Minute(10))
alertperiod!(v) = @set_preferences!("alertperiod"=>v)
lowerbound() = @load_preference("lowerbound", 18)
lowerbound!(v) = @set_preferences!("lowerbound"=>v)
higherbound() = @load_preference("higherbound", 23)
higherbound!(v) = @set_preferences!("higherbound"=>v)
admins() = @load_preference("admins", [])
admins!(v...) = @set_preferences!("admins"=>collect(v))
clients() = @load_preference("clients", [])
clients!(v...) = @set_preferences!("clients"=>collect(v))
token() = @load_preference("token")
token!(v) = @set_preferences!("token"=>v)

function storevalue(bot)
    val = processvalue(bot.process)
    t = now()
    Arrow.append(bot.storage, (time=[t], temperature=[val]))
    @debug "Read value $val."
    t,val
end

function crontask(bot)
	try
		while timedwait(()->bot.exit, 1.0) == :timed_out
			if now() - bot.lastread ≥ pollperiod()
				t,val = storevalue(bot)
				bot.lastread = t 
				if val < lowerbound()
					signallowerbound(bot, val)
				elseif val > higherbound()
					signalhigherbound(bot, val)
				end
			end
		end
	catch e
		@error "Crontask failed" e stacktrace(catch_backtrace())
	end
end

function notifyall(bot, text)
    for chat_id in clients()
        sendMessage(bot.client; text, chat_id)
    end
end

function notifyadmins(bot, text)
    for chat_id in admins()
        sendMessage(bot.client; text, chat_id)
    end
end

function signallowerbound(bot, val)
	if now() - bot.lastalertdate > alertperiod() || bot.lastalert != :lower
		bot.lastalertdate = now()
		bot.lastalert = :lower
		@debug "Signaling lower bound value $val."
		notifyall(bot, "Temperature is $val °C! 🥶")
	end
end

function signalhigherbound(bot, val)
	if now() - bot.lastalertdate > alertperiod() || bot.lastalert != :higher
		bot.lastalertdate = now()
		bot.lastalert = :higher
		@debug "Signaling higher bound value $val."
		notifyall(bot, "Temperature is $val °C! 🥵")
	end
end

"""
isallowed(bot, message)::Bool

Return true if a message is allowed for the bot.
"""
function isallowed(bot, message) 
    @debug "Got message" message
    message === nothing && return false
    chat = get(message, :chat, nothing)
    @debug "Got chat" chat
    chat === nothing && return false
    chat_id = get(chat, :id, nothing)
    @debug "Got chat_id" chat_id
    chat_id === nothing && return false
    if !(string(chat_id) in clients())
        if chat_id ∉ bot.known_chat_id
            @info "New chat attempt from un-authorized chat: $chat_id"
            notifyadmins(bot,  "New chat attempt from un-authorized chat: $chat_id")
            push!(bot.known_chat_id, string(chat_id))
        end
        return false
    else 
        return true
    end
end

function make_exc_handler(bot)
    function cmdline_handler(settings::ArgParseSettings, err, err_code::Int = 1)
        # io = IOBuffer()
        # println(io, err.text)
        # println(io, usage_string(settings))
        # sendMessage(bot.client, text=String(take!(io)), chat_id=)
    end
end

function help(bot, chat_id, _)
    io = IOBuffer()
    ArgParse.show_help(io, bot.commandparsesettings)
    sendMessage(bot.client, text=String(take!(io)), chat_id=chat_id)
end

function settings(bot, chat_id, args)
	if all(isnothing, values(args))
		sendMessage(bot.client, text="""
			    Current settings:
			    * poll-period: $(pollperiod())
			    * lower-bound: $(lowerbound()) °C
			    * higher-bound: $(higherbound()) °C
			    * alert-period: $(alertperiod())
			    """, chat_id=chat_id)
	else
		if !isnothing(args["poll-period"])
			pollperiod!(args["poll-period"])
			sendMessage(bot.client, text="OK, set poll-period to $(pollperiod()).", chat_id=chat_id)
		end
		if !isnothing(args["lower-bound"])
			lowerbound!(args["lower-bound"])
			sendMessage(bot.client, text="OK, set lower-bound to $(lowerbound()).", chat_id=chat_id)
		end
		if !isnothing(args["higher-bound"])
			higherbound!(args["higher-bound"])
			sendMessage(bot.client, text="OK, set higher-bound to $(higherbound()).", chat_id=chat_id)
		end
		if !isnothing(args["alert-period"])
			alertperiod!(args["alert-period"])
			sendMessage(bot.client, text="OK, set alert-period to $(alertperiod()).", chat_id=chat_id)
		end
	end
end

function temperature(bot, chat_id, args)
    if isnothing(args["date1"])
        t,val = storevalue(bot)
        sendMessage(bot.client, text="[$t] Temperature is $val °C", chat_id=chat_id)
        return
    elseif isnothing(args["date2"])
        d = args["date1"]
        mini = DateTime(Dates.Year(d), Dates.Month(d), Dates.Day(d))
        maxi = mini + Dates.Day(1)
        title = "Temperature profile in Lab 66"
        subtitle = Dates.format(d, "Y-m-d")
        filename = Dates.format(now(), "Y-m-d") * ".png"
    else
        mini = min(args["date1"], args["date2"])
        maxi = max(args["date1"], args["date2"])
        title = "Temperature profile in Lab 66"
        subtitle = "From $mini to $maxi"
        filename = Dates.format(mini, "Y-m-d") * "_" * Dates.format(maxi, "Y-m-d") * ".png"
    end
    df = subset(DataFrame(Arrow.Table(bot.storage)), :time=>ByRow(t->mini≤t<maxi))
    fig = Figure()
    ax = Axis(fig[1,1], xlabel="Date", ylabel="Temperature [°C]", title=title)
    lines!(ax, df.time, df.temperature)
    io = IOBuffer()
    show(io, MIME"image/png"(), fig)
    sendPhoto(bot.client, photo=filename=>io, chat_id=chat_id)
end

COMMANDS = Dict([
    "help"=>help,
    "set"=>settings,
    "temp"=>temperature,
])

function make_callback(bot)
    function callback(update)
        message = get(update, :message, nothing)
        @debug "Getting message" message
        if !isallowed(bot, message)
            @debug "Not allowed!"
            return nothing
        end
        text = get(message, :text, nothing)
        @debug "Got text" text
        text === nothing && return nothing
        startswith(text, "/") || return nothing
        args = split(text[nextind(text, 1):end])
        parsed = parse_args(args, bot.commandparsesettings)
        @debug "Parsed arguments" parsed
        parsed === nothing && return nothing
        cmd = parsed["%COMMAND%"]
        chat = get(message, :chat)
        chat_id = get(chat, :id)
        COMMANDS[cmd](bot, chat_id, parsed[cmd])
    end
end

function main(_=nothing)
    bot = Bot(TEMPer())
    @info "Starting temperature monitoring. Please do not close this window."
    task_cron = Threads.@spawn crontask(bot)
    task_bot = Threads.@spawn run_bot(make_callback(bot))
    if isinteractive()
	    return bot
    else
	    wait(task_cron)
	    wait(task_bot)
	    return 0
    end
end

@static if isdefined(Base, Symbol("@main"))
	@main
end

end
