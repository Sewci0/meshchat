// A repeater's (and room server's) command line, as MeshCore's firmware implements it
// (src/helpers/CommonCLI.cpp, CommonRadioPrefs.cpp, examples/simple_repeater/MyMesh.cpp). An admin
// runs these remotely; the node answers each with up to about 160 characters. Only commands that work
// over the mesh are here: not the ones the firmware takes only over serial (erase, log, stats-*,
// get acl, get prv.key, set freq), nor region load, which reads the following lines until a blank one.

export type CommandGroup = "Actions" | "Clock" | "Information" | "Neighbours" | "Access" | "Radio" | "Power and GPS" | "Logging" | "Regions" | "Sensors"

export interface AdminCommand {
  /** what to send; `<…>` marks a value to fill in */
  command: string
  label: string
  about: string
  group: CommandGroup
  /** asks first, saying this */
  confirm?: string
}

export const COMMANDS: AdminCommand[] = [
  // actions
  { command: "reboot", label: "Restart", group: "Actions", about: "Restarts the repeater. It's off the air for about 15 seconds; settings are kept.",
    confirm: "It stops repeating for about 15 seconds while it restarts." },
  { command: "advert", label: "Send flood advert", group: "Actions", about: "Announces the repeater to the whole mesh, so others can find it and route through it." },
  { command: "advert.zerohop", label: "Send zero-hop advert", group: "Actions", about: "Announces it only to radios that hear it directly." },
  { command: "clear stats", label: "Clear statistics", group: "Actions", about: "Resets its packet and airtime counters to zero.",
    confirm: "Its traffic counters start again from zero." },
  { command: "start ota", label: "Start firmware update", group: "Actions", about: "Puts it in firmware-update mode (it opens a WiFi or Bluetooth update service, depending on the board). It stops repeating until updated or restarted.",
    confirm: "It stops repeating until it's updated or restarted, and someone must be near it to finish the update." },
  { command: "poweroff", label: "Power off", group: "Actions", about: "Turns it off. It can't be turned back on remotely.",
    confirm: "It can't be turned on again remotely: someone has to go to it." },
  { command: "clkreboot", label: "Reset clock and restart", group: "Actions", about: "Sets its clock back to May 2024 and restarts: for a clock that's stuck far in the future.",
    confirm: "Its clock goes back to May 2024 and it restarts. Sync the clock afterwards." },

  // clock
  { command: "clock", label: "Show clock", group: "Clock", about: "Its time, in UTC." },
  { command: "clock sync", label: "Sync clock", group: "Clock", about: "Sets its clock from your radio's (it can only go forward)." },
  { command: "time <epoch seconds>", label: "Set time", group: "Clock", about: "Sets its clock to a Unix time (forward only)." },

  // information
  { command: "ver", label: "Firmware version", group: "Information", about: "Its firmware version and build date." },
  { command: "board", label: "Board", group: "Information", about: "The hardware it runs on." },
  { command: "power", label: "Power", group: "Information", about: "Battery voltage, and whether USB, solar or external power is present." },
  { command: "get public.key", label: "Public key", group: "Information", about: "Its public key (its identity on the mesh)." },
  { command: "get role", label: "Role", group: "Information", about: "What the firmware is: repeater, room server, sensor…" },
  { command: "get bootloader.ver", label: "Bootloader version", group: "Information", about: "Its bootloader version (some boards)." },
  { command: "get pwrmgt.support", label: "Power management", group: "Information", about: "Whether the board supports power management." },
  { command: "get pwrmgt.source", label: "Power source", group: "Information", about: "Where its power comes from, if the board can tell." },
  { command: "get pwrmgt.bootreason", label: "Last boot reason", group: "Information", about: "Why it last started (power on, watchdog, low battery…)." },
  { command: "get pwrmgt.bootmv", label: "Boot voltage", group: "Information", about: "The battery voltage when it last started." },

  // neighbours
  { command: "neighbors", label: "List neighbours", group: "Neighbours", about: "The repeaters it hears directly, with signal and when last heard." },
  { command: "discover.neighbors", label: "Discover neighbours", group: "Neighbours", about: "Asks the repeaters around it to answer, to fill its neighbour list now." },
  { command: "neighbor.remove <public key hex>", label: "Remove a neighbour", group: "Neighbours", about: "Forgets one neighbour (by its key or the start of it)." },

  // access
  { command: "password <new admin password>", label: "Change admin password", group: "Access", about: "Sets a new admin password (up to 15 characters). Note it: without it nobody can administer the repeater remotely.",
    confirm: "Without the new password nobody can administer it remotely. MeshChat doesn't keep it." },
  { command: "get guest.password", label: "Guest password", group: "Access", about: "The password that gives guest access (empty: none)." },
  { command: "set guest.password <password>", label: "Set guest password", group: "Access", about: "Sets the guest password (empty to remove it)." },
  { command: "get allow.read.only", label: "Read-only access", group: "Access", about: "Whether logins without a password get read-only access." },
  { command: "set allow.read.only <on|off>", label: "Set read-only access", group: "Access", about: "Lets logins without a password in, read-only." },
  { command: "setperm <public key hex> <0-3>", label: "Set someone's role", group: "Access", about: "Gives a node a role: 0 guest, 1 read-only, 2 read-write, 3 admin." },
  { command: "set prv.key <64-byte hex>", label: "Replace private key", group: "Access", about: "Gives it a new identity. Everyone's contact for it stops working.",
    confirm: "It becomes a different node: every contact and route to it stops working." },

  // radio and repeating
  { command: "get radio", label: "Radio settings", group: "Radio", about: "Frequency (MHz), bandwidth (kHz), spreading factor and coding rate." },
  { command: "set radio <freq>,<bw>,<sf>,<cr>", label: "Set radio", group: "Radio", about: "Changes its network, for example 869.618,62.5,6,8. A wrong value takes it off your network, out of reach.",
    confirm: "If it's not your network's settings, the repeater goes silent for you and you can't reach it to fix it." },
  { command: "tempradio <freq> <bw> <sf> <cr> <minutes>", label: "Try radio settings", group: "Radio", about: "Uses other radio settings for a number of minutes, then goes back by itself.",
    confirm: "For those minutes it can't hear your network." },
  { command: "get freq", label: "Frequency", group: "Radio", about: "Its frequency in MHz." },
  { command: "get tx", label: "Transmit power", group: "Radio", about: "Its transmit power in dBm." },
  { command: "set tx <dBm>", label: "Set transmit power", group: "Radio", about: "Sets its transmit power. Keep within your country's limit (EU, 869.4–869.65 MHz: 27 dBm ERP)." },
  { command: "get repeat", label: "Repeating", group: "Radio", about: "Whether it passes on other nodes' packets." },
  { command: "set repeat <on|off>", label: "Set repeating", group: "Radio", about: "Turns repeating on or off. Off, it no longer relays anything.",
    confirm: "Off, it stops relaying for everyone." },
  { command: "get af", label: "Airtime factor", group: "Radio", about: "How long it waits after transmitting, in multiples of the packet's airtime (duty cycle)." },
  { command: "set af <0-9>", label: "Set airtime factor", group: "Radio", about: "Sets the airtime factor." },
  { command: "get dutycycle", label: "Duty cycle", group: "Radio", about: "The share of time it may transmit, in percent." },
  { command: "set dutycycle <1-100>", label: "Set duty cycle", group: "Radio", about: "Sets the duty cycle limit (EU 869.4–869.65 MHz: 10%)." },
  { command: "get rxdelay", label: "Receive delay", group: "Radio", about: "Base delay before relaying a flood, weighted by signal: weaker copies wait longer." },
  { command: "set rxdelay <0-20>", label: "Set receive delay", group: "Radio", about: "Sets the receive delay base." },
  { command: "get txdelay", label: "Flood TX delay", group: "Radio", about: "Random delay factor before relaying floods." },
  { command: "set txdelay <factor>", label: "Set flood TX delay", group: "Radio", about: "Sets the flood relay delay factor." },
  { command: "get direct.txdelay", label: "Direct TX delay", group: "Radio", about: "Random delay factor before relaying direct packets." },
  { command: "set direct.txdelay <factor>", label: "Set direct TX delay", group: "Radio", about: "Sets the direct relay delay factor." },
  { command: "get int.thresh", label: "Interference threshold", group: "Radio", about: "Listen-before-talk threshold." },
  { command: "set int.thresh <value>", label: "Set interference threshold", group: "Radio", about: "Sets the listen-before-talk threshold." },
  { command: "get cad", label: "Channel activity detection", group: "Radio", about: "Whether it checks the channel is free before transmitting." },
  { command: "set cad <on|off>", label: "Set channel activity detection", group: "Radio", about: "Turns channel activity detection on or off." },
  { command: "get agc.reset.interval", label: "AGC reset interval", group: "Radio", about: "How often the receiver's gain control is reset, in seconds." },
  { command: "set agc.reset.interval <seconds>", label: "Set AGC reset interval", group: "Radio", about: "Sets the AGC reset interval." },
  { command: "get radio.rxgain", label: "Boosted RX gain", group: "Radio", about: "Whether the receiver's boosted gain is on (some radios)." },
  { command: "set radio.rxgain <on|off>", label: "Set boosted RX gain", group: "Radio", about: "Turns boosted receive gain on or off." },
  { command: "get multi.acks", label: "Multiple ACKs", group: "Radio", about: "How many extra ACKs it sends." },
  { command: "set multi.acks <0-2>", label: "Set multiple ACKs", group: "Radio", about: "Sets how many extra ACKs it sends." },
  { command: "get path.hash.mode", label: "Path ID size", group: "Radio", about: "How many bytes of its key it puts in paths (0: 1 byte, 1: 2 bytes, 2: 3 bytes)." },
  { command: "set path.hash.mode <0-2>", label: "Set path ID size", group: "Radio", about: "Sets the path ID size. Keep it the same as the rest of your network.",
    confirm: "Repeaters with different ID sizes can't name each other in routes." },
  { command: "get flood.max", label: "Flood hop limit", group: "Radio", about: "The most hops a flood may have taken for it to still relay it." },
  { command: "set flood.max <hops>", label: "Set flood hop limit", group: "Radio", about: "Sets the flood hop limit." },
  { command: "get flood.max.advert", label: "Advert hop limit", group: "Radio", about: "The hop limit for flooded adverts." },
  { command: "set flood.max.advert <hops>", label: "Set advert hop limit", group: "Radio", about: "Sets the advert hop limit." },
  { command: "get flood.max.unscoped", label: "Unscoped flood limit", group: "Radio", about: "The hop limit for floods without a region." },
  { command: "set flood.max.unscoped <hops>", label: "Set unscoped flood limit", group: "Radio", about: "Sets the hop limit for floods without a region." },
  { command: "get loop.detect", label: "Loop detection", group: "Radio", about: "How strictly it drops packets that loop: off, minimal, moderate or strict." },
  { command: "set loop.detect <off|minimal|moderate|strict>", label: "Set loop detection", group: "Radio", about: "Sets loop detection." },
  { command: "get extra.sf", label: "Extra spreading factor", group: "Radio", about: "A second spreading factor it also listens on, if any." },
  { command: "set extra.sf <sf>", label: "Set extra spreading factor", group: "Radio", about: "Sets the extra spreading factor." },

  // identity and adverts (in Radio's company, but about the node)
  { command: "get name", label: "Name", group: "Access", about: "Its name on the mesh." },
  { command: "set name <name>", label: "Rename", group: "Access", about: "Renames it (up to 31 bytes). Others see the new name after its next advert." },
  { command: "get lat", label: "Latitude", group: "Access", about: "Its latitude, as its adverts give it." },
  { command: "set lat <degrees>", label: "Set latitude", group: "Access", about: "Sets its latitude." },
  { command: "get lon", label: "Longitude", group: "Access", about: "Its longitude." },
  { command: "set lon <degrees>", label: "Set longitude", group: "Access", about: "Sets its longitude." },
  { command: "get owner.info", label: "Owner info", group: "Access", about: "Free text about who runs it." },
  { command: "set owner.info <text>", label: "Set owner info", group: "Access", about: "Sets the owner text." },
  { command: "get advert.interval", label: "Zero-hop advert interval", group: "Access", about: "Minutes between its automatic zero-hop adverts." },
  { command: "set advert.interval <minutes>", label: "Set zero-hop advert interval", group: "Access", about: "Sets the zero-hop advert interval (0: off)." },
  { command: "get flood.advert.interval", label: "Flood advert interval", group: "Access", about: "Hours between its automatic flood adverts." },
  { command: "set flood.advert.interval <hours>", label: "Set flood advert interval", group: "Access", about: "Sets the flood advert interval (0: off)." },

  // power and GPS
  { command: "powersaving", label: "Power saving", group: "Power and GPS", about: "Whether power saving is on." },
  { command: "powersaving on", label: "Power saving on", group: "Power and GPS", about: "Turns power saving on (ESP32: after 2 minutes)." },
  { command: "powersaving off", label: "Power saving off", group: "Power and GPS", about: "Turns power saving off." },
  { command: "get adc.multiplier", label: "Battery reading factor", group: "Power and GPS", about: "The calibration factor for its battery voltage." },
  { command: "set adc.multiplier <factor>", label: "Set battery reading factor", group: "Power and GPS", about: "Calibrates its battery voltage reading." },
  { command: "gps", label: "GPS status", group: "Power and GPS", about: "Whether it has GPS, a fix and how many satellites." },
  { command: "gps on", label: "GPS on", group: "Power and GPS", about: "Turns GPS on." },
  { command: "gps off", label: "GPS off", group: "Power and GPS", about: "Turns GPS off." },
  { command: "gps sync", label: "Set clock from GPS", group: "Power and GPS", about: "Sets its clock from GPS time." },
  { command: "gps setloc", label: "Set position from GPS", group: "Power and GPS", about: "Saves its GPS position as its advertised position." },
  { command: "gps advert", label: "Advert position policy", group: "Power and GPS", about: "Which position its adverts carry: none, prefs (the saved one) or share (live GPS)." },
  { command: "gps advert <none|prefs|share>", label: "Set advert position policy", group: "Power and GPS", about: "Sets which position its adverts carry." },
  { command: "gps diag", label: "GPS diagnostics", group: "Power and GPS", about: "GPS receiver details." },

  // logging, regions, sensors, bridge
  { command: "log start", label: "Start packet log", group: "Logging", about: "Starts logging packets to its storage (read it over USB)." },
  { command: "log stop", label: "Stop packet log", group: "Logging", about: "Stops logging packets." },
  { command: "log erase", label: "Erase packet log", group: "Logging", about: "Deletes its packet log.", confirm: "Its stored packet log is deleted." },
  { command: "region", label: "Regions", group: "Regions", about: "The flood regions it knows (flood scope); F marks those it floods." },
  { command: "region list <allowed|denied>", label: "List regions", group: "Regions", about: "The regions it floods (allowed) or doesn't (denied)." },
  { command: "region get <name>", label: "Show a region", group: "Regions", about: "A region, its parent, and whether it floods there." },
  { command: "region home", label: "Home region", group: "Regions", about: "Its home region." },
  { command: "region home <name>", label: "Set home region", group: "Regions", about: "Sets its home region." },
  { command: "region default", label: "Default scope", group: "Regions", about: "The region it gives floods that have none." },
  { command: "region default <name>", label: "Set default scope", group: "Regions", about: "Sets the default scope (<null> for none); a new name is created." },
  { command: "region put <name> <parent>", label: "Add a region", group: "Regions", about: "Adds a region under a parent (leave the parent out for the top level). It floods there." },
  { command: "region remove <name>", label: "Remove a region", group: "Regions", about: "Removes a region that has no regions under it." },
  { command: "region allowf <name>", label: "Flood in a region", group: "Regions", about: "Lets it relay floods scoped to that region." },
  { command: "region denyf <name>", label: "Stop flooding in a region", group: "Regions", about: "Stops it relaying floods scoped to that region." },
  { command: "region def <regions>", label: "Define regions", group: "Regions", about: "Defines several regions in one line (see MeshCore's documentation for the format)." },
  { command: "region save", label: "Save regions", group: "Regions", about: "Saves region changes so they survive a restart." },
  { command: "sensor list", label: "Sensor settings", group: "Sensors", about: "Its sensor settings (custom variables)." },
  { command: "sensor get <name>", label: "Read a sensor setting", group: "Sensors", about: "One sensor setting." },
  { command: "sensor set <name> <value>", label: "Change a sensor setting", group: "Sensors", about: "Changes a sensor setting." },
  { command: "get bridge.enabled", label: "Bridge", group: "Sensors", about: "Whether its packet bridge (to another radio or serial) is on." },
  { command: "set bridge.enabled <on|off>", label: "Set bridge", group: "Sensors", about: "Turns the bridge on or off." },
]

/** The settings shown as a form: read with `get <name>`, changed with `set <name> <value>`. */
export interface Setting { name: string; label: string; hint: string; group: "Node" | "Radio" | "Access"; options?: string[]; confirm?: string }

export const SETTINGS: Setting[] = [
  { name: "name", label: "Name", hint: "up to 31 bytes", group: "Node" },
  { name: "lat", label: "Latitude", hint: "degrees", group: "Node" },
  { name: "lon", label: "Longitude", hint: "degrees", group: "Node" },
  { name: "owner.info", label: "Owner info", hint: "free text", group: "Node" },
  { name: "advert.interval", label: "Zero-hop advert every", hint: "minutes, 0 off", group: "Node" },
  { name: "flood.advert.interval", label: "Flood advert every", hint: "hours, 0 off", group: "Node" },
  { name: "repeat", label: "Repeating", hint: "", group: "Radio", options: ["on", "off"], confirm: "Off, it stops relaying for everyone." },
  { name: "radio", label: "Radio", hint: "freq,bw,sf,cr", group: "Radio",
    confirm: "If it's not your network's settings, the repeater goes silent for you and you can't reach it to fix it." },
  { name: "tx", label: "Transmit power", hint: "dBm", group: "Radio" },
  { name: "af", label: "Airtime factor", hint: "0–9", group: "Radio" },
  { name: "flood.max", label: "Flood hop limit", hint: "hops", group: "Radio" },
  { name: "loop.detect", label: "Loop detection", hint: "", group: "Radio", options: ["off", "minimal", "moderate", "strict"] },
  { name: "rxdelay", label: "Receive delay", hint: "0–20", group: "Radio" },
  { name: "txdelay", label: "Flood TX delay", hint: "factor", group: "Radio" },
  { name: "direct.txdelay", label: "Direct TX delay", hint: "factor", group: "Radio" },
  { name: "guest.password", label: "Guest password", hint: "empty: none", group: "Access" },
  { name: "allow.read.only", label: "Read-only without password", hint: "", group: "Access", options: ["on", "off"] },
]

/** A command's answer, as a setting value: the firmware answers `get` with "> value". */
export const settingValue = (answer: string) => (answer.startsWith("> ") ? answer.slice(2) : answer)
