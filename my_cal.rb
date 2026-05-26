#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
#
# my_cal - A native Ruby replica of gcalcli features with custom calendar aliases.
# Communicates directly with the Google Calendar API using existing gcalcli credentials.
#
# Usage:
#   ./my_cal list
#   ./my_cal week
#   ./my_cal alias <name> <shortcut>
#

require 'json'
require 'net/http'
require 'uri'
require 'date'
require 'time'
require 'erb'
require 'rainbow'
require 'open3'
require 'fileutils'
require 'rbconfig'
require 'io/console'

DEFAULT_OAUTH_PATH = File.expand_path("~/.local/share/gcalcli/oauth") unless defined?(DEFAULT_OAUTH_PATH)

# Ensure persistent config directory exists
CONFIG_DIR = File.expand_path("~/.config/my_cal") unless defined?(CONFIG_DIR)
FileUtils.mkdir_p(CONFIG_DIR) unless Dir.exist?(CONFIG_DIR)

ALIASES_FILE = File.join(CONFIG_DIR, "aliases.json") unless defined?(ALIASES_FILE)
CREDENTIALS_FILE = File.join(CONFIG_DIR, "credentials.json") unless defined?(CREDENTIALS_FILE)
CACHE_FILE = File.join(CONFIG_DIR, "calendar_cache.json") unless defined?(CACHE_FILE)

# Loads aliases from config file
def load_aliases
  if File.exist?(ALIASES_FILE)
    begin
      JSON.parse(File.read(ALIASES_FILE))
    rescue
      {}
    end
  else
    {}
  end
end

# Saves aliases to config file
def save_aliases(aliases)
  File.write(ALIASES_FILE, JSON.generate(aliases))
end

# Extracts gcalcli oauth credentials from python pickle file
def get_oauth_credentials(oauth_path)
  unless File.exist?(oauth_path)
    raise "Credentials file not found at #{oauth_path}. Please authenticate using gcalcli first."
  end

  python_code = <<~PYTHON
    import pickle, json, sys
    try:
        with open('#{oauth_path}', 'rb') as f:
            c = pickle.load(f)
        print(json.dumps({
            'token': c.token,
            'refresh_token': c.refresh_token,
            'token_uri': c.token_uri,
            'client_id': c.client_id,
            'client_secret': c.client_secret
        }))
    except Exception as e:
        print(json.dumps({'error': str(e)}))
        sys.exit(1)
  PYTHON

  stdout, stderr, status = Open3.capture3("python3", stdin_data: python_code)
  if !status.success? || stdout.strip.empty?
    raise "Failed to extract credentials via Python subprocess: #{stderr}"
  end

  data = JSON.parse(stdout)
  if data['error']
    raise "Credentials error: #{data['error']}"
  end
  data
end

# Refreshes the OAuth2 access token
def refresh_access_token(credentials)
  uri = URI(credentials['token_uri'] || "https://oauth2.googleapis.com/token")
  req = Net::HTTP::Post.new(uri)
  req.set_form_data({
    'client_id' => credentials['client_id'],
    'client_secret' => credentials['client_secret'],
    'refresh_token' => credentials['refresh_token'],
    'grant_type' => 'refresh_token'
  })

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  res = http.request(req)
  unless res.is_a?(Net::HTTPSuccess)
    raise "Failed to refresh token: #{res.code} - #{res.body}"
  end

  data = JSON.parse(res.body)
  expires_in = data['expires_in'] || 3600
  {
    'access_token' => data['access_token'],
    'expires_at' => Time.now.to_i + expires_in - 60
  }
end

# Saves credentials to config file
def save_credentials(creds)
  File.write(CREDENTIALS_FILE, JSON.generate(creds))
end

# Loads credentials from our persistent file, or imports from gcalcli on first run
def get_credentials(oauth_path)
  if File.exist?(CREDENTIALS_FILE)
    begin
      return JSON.parse(File.read(CREDENTIALS_FILE))
    rescue => e
      # fallback to import if credentials file is corrupted
    end
  end

  # If credentials don't exist in config, import them from gcalcli
  puts Rainbow("Initializing credentials from gcalcli on first run...").yellow
  creds = get_oauth_credentials(oauth_path)
  
  # Ensure standard fields are populated
  creds['access_token'] ||= creds['token']
  creds['expires_at'] ||= Time.now.to_i # force immediate refresh to populate expires_at
  
  save_credentials(creds)
  creds
end

# Fetches access token from credentials file or refreshes if necessary
def get_access_token(oauth_path)
  creds = get_credentials(oauth_path)

  if creds['access_token'] && creds['expires_at'] && Time.now.to_i < creds['expires_at']
    return creds['access_token']
  end

  # Token is missing or expired, refresh it
  begin
    refreshed = refresh_access_token(creds)
    creds['access_token'] = refreshed['access_token']
    creds['expires_at'] = refreshed['expires_at']
    save_credentials(creds)
  rescue => e
    raise "Failed to refresh token: #{e.message}. Please check credentials in #{CREDENTIALS_FILE}."
  end

  creds['access_token']
end

# Helper to fetch calendar list
def fetch_calendar_list(access_token)
  uri = URI("https://www.googleapis.com/calendar/v3/users/me/calendarList")
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{access_token}"

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  res = http.request(req)
  unless res.is_a?(Net::HTTPSuccess)
    raise "Failed to fetch calendar list: #{res.code} - #{res.body}"
  end

  JSON.parse(res.body)['items'] || []
end

# Command: list
def list_calendars(access_token)
  calendars = fetch_calendar_list(access_token)
  aliases = load_aliases

  puts Rainbow("Calendars:").bold.underline.cyan
  puts
  alias_header = Rainbow(sprintf("%-12s", "Alias")).bold
  role_header = Rainbow(sprintf("%-10s", "Role")).bold
  selected_header = Rainbow(sprintf("%-8s", "Selected")).bold
  name_header = Rainbow(sprintf("%-30s", "Calendar Name")).bold

  puts "  #{alias_header} | #{role_header} | #{selected_header} | #{name_header}"
  puts "  " + "-" * 71

  calendars.each do |cal|
    name = cal['summaryOverride'] || cal['summary'] || "(No Name)"
    role = cal['accessRole'] || "unknown"
    selected = cal['selected'] ? "yes" : "no"
    shortcut = aliases[cal['id']] || "-"

    role_color = case role
                 when 'owner' then :green
                 when 'writer' then :yellow
                 else :blue
                 end

    selected_color = cal['selected'] ? :cyan : :default
    alias_color = shortcut != "-" ? :magenta : :default

    colored_shortcut = Rainbow(sprintf("%-12s", shortcut)).color(alias_color).bold
    colored_role = Rainbow(sprintf("%-10s", role)).color(role_color)
    colored_selected = Rainbow(sprintf("%-8s", selected)).color(selected_color)
    colored_name = Rainbow(sprintf("%-30s", name)).bold

    puts "  #{colored_shortcut} | #{colored_role} | #{colored_selected} | #{colored_name}"
  end
end

# Helper to fetch events for a specific calendar
def fetch_calendar_events(access_token, calendar_id, time_min, time_max)
  params = URI.encode_www_form({
    'timeMin' => time_min.iso8601,
    'timeMax' => time_max.iso8601,
    'singleEvents' => 'true',
    'orderBy' => 'startTime'
  })

  uri = URI("https://www.googleapis.com/calendar/v3/calendars/#{ERB::Util.url_encode(calendar_id)}/events?#{params}")
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{access_token}"

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  res = http.request(req)
  unless res.is_a?(Net::HTTPSuccess)
    warn Rainbow("Warning: Failed to fetch events for #{calendar_id}: #{res.code}").yellow
    return []
  end

  JSON.parse(res.body)['items'] || []
end

# Helper to parse start/end times of an event
def parse_event_time(event)
  if event['start'] && event['start']['dateTime']
    start_time = Time.parse(event['start']['dateTime']).localtime
    end_time = Time.parse(event['end']['dateTime']).localtime
    all_day = false
  elsif event['start'] && event['start']['date']
    start_date = Date.parse(event['start']['date'])
    end_date = Date.parse(event['end']['date'])
    start_time = Time.local(start_date.year, start_date.month, start_date.day, 0, 0, 0)
    end_time = Time.local(end_date.year, end_date.month, end_date.day, 0, 0, 0)
    all_day = true
  else
    start_time = Time.now
    end_time = Time.now
    all_day = false
  end
  { start_time: start_time, end_time: end_time, all_day: all_day }
end

# Assign color dynamically to selected calendars
def get_calendar_colors(calendars)
  available_colors = [:cyan, :green, :yellow, :magenta, :blue, :orange]
  colors_map = {}
  calendars.each_with_index do |cal, idx|
    colors_map[cal['id']] = available_colors[idx % available_colors.size]
  end
  colors_map
end

# Parses priority from event description, clamping it to range 0..10.0
def parse_priority(description)
  if description && description =~ /^priority:\s*(-?\d+(?:\.\d+)?)/i
    val = $1.to_f
    [[val, 0.0].max, 10.0].min
  else
    nil
  end
end

# Colors priority: blue by default, and bright bold red if >= 8.0
def format_priority_rainbow(prio_str, priority)
  if priority >= 8.0
    Rainbow(prio_str).color(:red).bright.bold
  else
    Rainbow(prio_str).color(:blue).bold
  end
end

# Renders an event line with calendar-specific colors, right-aligned priority, friendly ID, and recurrence frequency
def render_event_line(time_str, cal_summary, cal_color, summary, priority, show_id = false, event_id = nil, show_recurrence = false, recurrence_freq = nil)
  # Target width of text inside the borders to align all the way to character 80:
  # "│  " (3 chars) + content (77 chars) = 80 chars.
  target_content_width = 77

  time_plain = time_str.ljust(13)
  cal_plain = "[#{cal_summary}]"

  if show_id && event_id
    id_tag = "[#{event_id}] "
  else
    id_tag = ""
  end

  if show_recurrence && recurrence_freq
    rec_tag = "(⟲ #{recurrence_freq}) "
  else
    rec_tag = ""
  end

  if priority
    prio_str = (priority % 1 == 0) ? priority.to_i.to_s : sprintf("%.1f", priority)
  else
    prio_str = ""
  end

  if priority
    available_summary_width = target_content_width - 13 - 2 - cal_plain.length - 1 - id_tag.length - rec_tag.length - 1 - prio_str.length
    truncated_summary = summary.length > available_summary_width ? summary[0...[0, available_summary_width - 3].max] + "..." : summary

    padding_length = target_content_width - 13 - 2 - cal_plain.length - 1 - id_tag.length - rec_tag.length - truncated_summary.length - prio_str.length
    padding = " " * [0, padding_length].max

    colored_prio = format_priority_rainbow(prio_str, priority)

    puts sprintf("│  %s  [%s] %s%s%s%s%s",
                 Rainbow(sprintf("%-13s", time_str)).green,
                 Rainbow(cal_summary).color(cal_color),
                 Rainbow(id_tag).color(128, 128, 128),
                 Rainbow(rec_tag).color(0, 128, 128).italic,
                 Rainbow(truncated_summary).bold,
                 padding,
                 colored_prio)
  else
    available_summary_width = target_content_width - 13 - 2 - cal_plain.length - 1 - id_tag.length - rec_tag.length
    truncated_summary = summary.length > available_summary_width ? summary[0...[0, available_summary_width - 3].max] + "..." : summary

    puts sprintf("│  %s  [%s] %s%s%s",
                 Rainbow(sprintf("%-13s", time_str)).green,
                 Rainbow(cal_summary).color(cal_color),
                 Rainbow(id_tag).color(128, 128, 128),
                 Rainbow(rec_tag).color(0, 128, 128).italic,
                 Rainbow(truncated_summary).bold)
  end
end

# Command: week
def show_week_schedule(access_token, calendar_name = nil, show_id = false, show_recurrence = false)
  all_calendars = get_cached_calendar_list(access_token)
  aliases = load_aliases

  if calendar_name
    cal = resolve_calendar(access_token, calendar_name)
    unless cal
      puts Rainbow("Error: Calendar '#{calendar_name}' not found.").red.bright
      exit 1
    end
    selected_calendars = [cal]
  else
    # Filter selected calendars (or use primary if none selected)
    selected_calendars = all_calendars.select { |c| c['selected'] }
    if selected_calendars.empty?
      primary = all_calendars.find { |c| c['primary'] } || all_calendars.first
      selected_calendars = [primary].compact
    end
  end

  calendar_map = {}
  selected_calendars.each do |cal|
    calendar_map[cal['id']] = {
      summary: cal['summaryOverride'] || cal['summary']
    }
  end

  color_assignments = get_calendar_colors(selected_calendars)

  # Calculate start and end of week (Monday to Sunday)
  today = Date.today
  days_since_monday = (today.wday - 1) % 7
  monday = today - days_since_monday
  sunday = monday + 6

  time_min = Time.local(monday.year, monday.month, monday.day, 0, 0, 0)
  time_max = Time.local(sunday.year, sunday.month, sunday.day, 23, 59, 59)

  puts Rainbow("Weekly Schedule: #{monday.strftime('%B %d, %Y')} to #{sunday.strftime('%B %d, %Y')}").bold.underline.cyan
  puts

  all_events = []
  cached_events_by_calendar = get_cached_calendar_events(access_token)

  selected_calendars.each do |cal|
    events = cached_events_by_calendar[cal['id']] || []
    events.each do |event|
      times = parse_event_time(event)
      if times[:start_time] >= time_min && times[:start_time] <= time_max
        event['_calendar_id'] = cal['id']
        event['_calendar_summary'] = calendar_map[cal['id']][:summary]
        all_events << event
      end
    end
  end

  parsed_events = all_events.map do |event|
    times = parse_event_time(event)
    {
      event: event,
      start_time: times[:start_time],
      end_time: times[:end_time],
      all_day: times[:all_day],
      calendar_id: event['_calendar_id'],
      calendar_summary: event['_calendar_summary'],
      priority: parse_priority(event['description'])
    }
  end

  # Filter events within the range
  parsed_events = parsed_events.select do |pe|
    pe[:start_time] >= time_min && pe[:start_time] <= time_max
  end

  # Group by day
  events_by_day = parsed_events.group_by { |pe| pe[:start_time].to_date }

  has_events = false
  (0..6).each do |offset|
    day_date = monday + offset
    day_events = events_by_day[day_date] || []

    next if day_events.empty?
    has_events = true

    day_name = day_date.strftime("%A, %B %d")
    border_prefix = "┌── #{day_name} "
    padding_dashes = [0, 80 - border_prefix.length].max
    puts Rainbow(border_prefix + "─" * padding_dashes).bold.yellow

    # Sort events: all-day first, then by start_time, then end_time, then summary
    sorted_events = day_events.sort_by do |pe|
      [pe[:all_day] ? 0 : 1, pe[:start_time], pe[:end_time], pe[:event]['summary'] || ""]
    end

    sorted_events.each do |pe|
      summary = pe[:event]['summary'] || "(No Title)"
      cal_summary = aliases[pe[:calendar_id]] || pe[:calendar_summary]
      cal_color = color_assignments[pe[:calendar_id]] || :default

      if pe[:all_day]
        time_str = "All Day"
      else
        time_str = "#{pe[:start_time].strftime('%H:%M')} - #{pe[:end_time].strftime('%H:%M')}"
      end

      render_event_line(time_str, cal_summary, cal_color, summary, pe[:priority], show_id, pe[:event]['_friendly_id'], show_recurrence, pe[:event]['_recurrence_freq'])

      desc = pe[:event]['description']
      if desc && !desc.strip.empty?
        desc_lines = desc.strip.split("\n").reject { |line| line =~ /^\s*priority:\s*-?\d+(?:\.\d+)?\s*$/i }
        first_desc_line = desc_lines.first
        if first_desc_line && !first_desc_line.strip.empty?
          puts "│      " + Rainbow(first_desc_line).color(128, 128, 128).italic
        end
      end
    end
    puts
  end

  unless has_events
    puts Rainbow("No events scheduled for this week!").yellow
  end
end
# Command: today
def show_today_schedule(access_token, show_id = false, show_recurrence = false)
  all_calendars = get_cached_calendar_list(access_token)
  aliases = load_aliases

  # Filter selected calendars (or use primary if none selected)
  selected_calendars = all_calendars.select { |c| c['selected'] }
  if selected_calendars.empty?
    primary = all_calendars.find { |c| c['primary'] } || all_calendars.first
    selected_calendars = [primary].compact
  end

  calendar_map = {}
  selected_calendars.each do |cal|
    calendar_map[cal['id']] = {
      summary: cal['summaryOverride'] || cal['summary']
    }
  end

  color_assignments = get_calendar_colors(selected_calendars)

  # Calculate start of today and end of tomorrow
  today = Date.today
  tomorrow = today + 1

  time_min = Time.local(today.year, today.month, today.day, 0, 0, 0)
  time_max = Time.local(tomorrow.year, tomorrow.month, tomorrow.day, 23, 59, 59)

  puts Rainbow("Schedule for Today and Tomorrow: #{today.strftime('%B %d, %Y')} to #{tomorrow.strftime('%B %d, %Y')}").bold.underline.cyan
  puts

  all_events = []
  cached_events_by_calendar = get_cached_calendar_events(access_token)

  selected_calendars.each do |cal|
    events = cached_events_by_calendar[cal['id']] || []
    events.each do |event|
      times = parse_event_time(event)
      if times[:start_time] >= time_min && times[:start_time] <= time_max
        event['_calendar_id'] = cal['id']
        event['_calendar_summary'] = calendar_map[cal['id']][:summary]
        all_events << event
      end
    end
  end

  parsed_events = all_events.map do |event|
    times = parse_event_time(event)
    {
      event: event,
      start_time: times[:start_time],
      end_time: times[:end_time],
      all_day: times[:all_day],
      calendar_id: event['_calendar_id'],
      calendar_summary: event['_calendar_summary'],
      priority: parse_priority(event['description'])
    }
  end

  # Group by day
  events_by_day = parsed_events.group_by { |pe| pe[:start_time].to_date }

  has_events = false
  [today, tomorrow].each do |day_date|
    day_events = events_by_day[day_date] || []

    next if day_events.empty?
    has_events = true

    day_name = day_date.strftime("%A, %B %d")
    border_prefix = "┌── #{day_name} "
    padding_dashes = [0, 80 - border_prefix.length].max
    puts Rainbow(border_prefix + "─" * padding_dashes).bold.yellow

    # Sort events: all-day first, then by start_time, then end_time, then summary
    sorted_events = day_events.sort_by do |pe|
      [pe[:all_day] ? 0 : 1, pe[:start_time], pe[:end_time], pe[:event]['summary'] || ""]
    end

    sorted_events.each do |pe|
      summary = pe[:event]['summary'] || "(No Title)"
      cal_summary = aliases[pe[:calendar_id]] || pe[:calendar_summary]
      cal_color = color_assignments[pe[:calendar_id]] || :default

      if pe[:all_day]
        time_str = "All Day"
      else
        time_str = "#{pe[:start_time].strftime('%H:%M')} - #{pe[:end_time].strftime('%H:%M')}"
      end

      render_event_line(time_str, cal_summary, cal_color, summary, pe[:priority], show_id, pe[:event]['_friendly_id'], show_recurrence, pe[:event]['_recurrence_freq'])

      desc = pe[:event]['description']
      if desc && !desc.strip.empty?
        desc_lines = desc.strip.split("\n").reject { |line| line =~ /^\s*priority:\s*-?\d+(?:\.\d+)?\s*$/i }
        first_desc_line = desc_lines.first
        if first_desc_line && !first_desc_line.strip.empty?
          puts "│      " + Rainbow(first_desc_line).color(128, 128, 128).italic
        end
      end
    end
    puts
  end

  unless has_events
    puts Rainbow("No events scheduled for today or tomorrow!").yellow
  end
end

# Helper to format the countdown string for active/future events
def format_countdown(pe, now)
  if now >= pe[:start_time]
    # Active
    if pe[:all_day]
      "Happening Now (All Day)"
    else
      diff = pe[:end_time] - now
      hours = (diff / 3600).to_i
      mins = ((diff % 3600) / 60).to_i
      if hours > 0
        "Happening Now (ends in #{hours}h #{mins}m)"
      else
        "Happening Now (ends in #{mins}m)"
      end
    end
  else
    # Future
    if pe[:all_day]
      days = (pe[:start_time].to_date - now.to_date).to_i
      if days == 1
        "Starts Tomorrow (All Day)"
      else
        "Starts in #{days} days (All Day)"
      end
    else
      diff = pe[:start_time] - now
      hours = (diff / 3600).to_i
      mins = ((diff % 3600) / 60).to_i
      if hours > 24
        days = hours / 24
        rem_hours = hours % 24
        "Starts in #{days}d #{rem_hours}h #{mins}m"
      elsif hours > 0
        "Starts in #{hours}h #{mins}m"
      else
        "Starts in #{mins}m"
      end
    end
  end
end

# Command: next
def show_next_event(access_token, show_id = false)
  all_calendars = get_cached_calendar_list(access_token)
  aliases = load_aliases

  # Filter selected calendars (or use primary if none selected)
  selected_calendars = all_calendars.select { |c| c['selected'] }
  if selected_calendars.empty?
    primary = all_calendars.find { |c| c['primary'] } || all_calendars.first
    selected_calendars = [primary].compact
  end

  calendar_map = {}
  selected_calendars.each do |cal|
    calendar_map[cal['id']] = {
      summary: cal['summaryOverride'] || cal['summary']
    }
  end

  color_assignments = get_calendar_colors(selected_calendars)
  cached_events_by_calendar = get_cached_calendar_events(access_token)

  all_events = []
  selected_calendars.each do |cal|
    events = cached_events_by_calendar[cal['id']] || []
    events.each do |event|
      event['_calendar_id'] = cal['id']
      event['_calendar_summary'] = calendar_map[cal['id']][:summary]
      all_events << event
    end
  end

  now = Time.now
  parsed_events = all_events.map do |event|
    times = parse_event_time(event)
    {
      event: event,
      start_time: times[:start_time],
      end_time: times[:end_time],
      all_day: times[:all_day],
      calendar_id: event['_calendar_id'],
      calendar_summary: event['_calendar_summary'],
      priority: parse_priority(event['description']),
      recurrence_freq: event['_recurrence_freq']
    }
  end

  # Select future/active events
  candidates = parsed_events.select { |pe| pe[:end_time] > now }

  if candidates.empty?
    puts Rainbow("┌── Next Upcoming Event ────────────────────────────────────────────────────────").bold.cyan
    puts "│  " + Rainbow("No upcoming events found in selected calendars.").yellow
    puts "└" + "─" * 79
    puts
    return
  end

  # Sort candidates
  candidates.sort_by! do |pe|
    is_active = (now >= pe[:start_time] && now < pe[:end_time]) ? 0 : 1
    is_all_day = pe[:all_day] ? 1 : 0
    sorting_time = (is_active == 0) ? pe[:end_time] : pe[:start_time]
    [is_active, is_all_day, sorting_time]
  end

  next_pe = candidates.first
  event = next_pe[:event]
  summary = event['summary'] || "(No Title)"
  cal_summary = aliases[next_pe[:calendar_id]] || next_pe[:calendar_summary]
  cal_color = color_assignments[next_pe[:calendar_id]] || :default

  # Format time range
  if next_pe[:all_day]
    time_str = next_pe[:start_time].strftime('%A, %B %d, %Y') + " (All Day)"
  else
    start_date_str = next_pe[:start_time].strftime('%A, %B %d, %Y')
    end_date_str = next_pe[:end_time].strftime('%A, %B %d, %Y')
    if start_date_str == end_date_str
      time_str = "#{start_date_str}, #{next_pe[:start_time].strftime('%H:%M')} - #{next_pe[:end_time].strftime('%H:%M')}"
    else
      time_str = "#{next_pe[:start_time].strftime('%A, %B %d, %Y, %H:%M')} to #{next_pe[:end_time].strftime('%A, %B %d, %Y, %H:%M')}"
    end
  end

  is_active = (now >= next_pe[:start_time] && now < next_pe[:end_time])
  status_label = is_active ? "Happening Now" : "Next Upcoming Event"
  countdown_str = format_countdown(next_pe, now)

  # Border box
  border_title = "── #{status_label} "
  padding_dashes = [0, 80 - border_title.length - 3].max
  puts Rainbow("┌" + border_title + "─" * padding_dashes).bold.cyan

  id_tag = ""
  if show_id && event['_friendly_id']
    id_tag = " (ID: #{event['_friendly_id']})"
  end

  puts sprintf("│  %-12s %s", Rainbow("Event:").bold, Rainbow(summary + id_tag).bold)
  puts sprintf("│  %-12s %s", Rainbow("Calendar:").bold, Rainbow("[#{cal_summary}]").color(cal_color))
  puts sprintf("│  %-12s %s", Rainbow("Time:").bold, time_str)
  
  if event['_recurrence_freq']
    puts sprintf("│  %-12s %s", Rainbow("Recurrence:").bold, Rainbow("⟲ #{event['_recurrence_freq']}").color(0, 128, 128).italic)
  end

  if next_pe[:priority]
    prio_str = (next_pe[:priority] % 1 == 0) ? next_pe[:priority].to_i.to_s : sprintf("%.1f", next_pe[:priority])
    puts sprintf("│  %-12s %s", Rainbow("Priority:").bold, format_priority_rainbow(prio_str, next_pe[:priority]))
  end

  puts sprintf("│  %-12s %s", Rainbow("Countdown:").bold, Rainbow(countdown_str).green.bold)

  desc = event['description']
  if desc && !desc.strip.empty?
    desc_lines = desc.strip.split("\n").reject { |line| line =~ /^\s*priority:\s*-?\d+(?:\.\d+)?\s*$/i }
    first_desc_line = desc_lines.first
    if first_desc_line && !first_desc_line.strip.empty?
      puts "│  " + Rainbow("─" * 74).color(128, 128, 128)
      puts sprintf("│  %-12s %s", Rainbow("Notes:").bold, Rainbow(first_desc_line).color(128, 128, 128).italic)
    end
  end

  puts "└" + "─" * 79
  puts
end

def resolve_calendar(access_token, name_or_id)
  calendars = get_cached_calendar_list(access_token)
  aliases = load_aliases

  # Match exact alias shortcut first
  matched_alias = aliases.find { |id, shortcut| shortcut.downcase == name_or_id.downcase }
  if matched_alias
    cal = calendars.find { |c| c['id'] == matched_alias[0] }
    return cal if cal
  end

  # Match exact ID
  cal = calendars.find { |c| c['id'] == name_or_id }
  return cal if cal

  # Match exact summary (case-insensitive)
  cal = calendars.find { |c| (c['summaryOverride'] || c['summary']).downcase == name_or_id.downcase }
  return cal if cal

  # Match partial summary
  cal = calendars.find { |c| (c['summaryOverride'] || c['summary']).downcase.include?(name_or_id.downcase) }
  return cal if cal

  nil
end

# Command: alias
def set_calendar_alias(access_token, name_or_id, shortcut)
  cal = resolve_calendar(access_token, name_or_id)
  unless cal
    raise "Calendar '#{name_or_id}' not found."
  end

  aliases = load_aliases
  real_name = cal['summaryOverride'] || cal['summary']

  if shortcut.nil? || shortcut.strip.empty?
    # Remove alias
    aliases.delete(cal['id'])
    save_aliases(aliases)
    puts Rainbow("Alias removed for calendar '#{real_name}'.").yellow
  else
    aliases[cal['id']] = shortcut.strip
    save_aliases(aliases)
    puts Rainbow("Alias '#{shortcut}' set for calendar '#{real_name}' (ID: #{cal['id']}).").green
  end
end

# Command: month
# Command: month
def show_month_schedule(access_token, calendar_name = nil, show_id = false, show_recurrence = false)
  all_calendars = get_cached_calendar_list(access_token)
  aliases = load_aliases

  if calendar_name
    cal = resolve_calendar(access_token, calendar_name)
    unless cal
      puts Rainbow("Error: Calendar '#{calendar_name}' not found.").red.bright
      exit 1
    end
    selected_calendars = [cal]
  else
    selected_calendars = all_calendars.select { |c| c['selected'] }
    if selected_calendars.empty?
      primary = all_calendars.find { |c| c['primary'] } || all_calendars.first
      selected_calendars = [primary].compact
    end
  end

  calendar_map = {}
  selected_calendars.each do |c|
    calendar_map[c['id']] = {
      summary: c['summaryOverride'] || c['summary'],
      shortcut: aliases[c['id']] || c['summaryOverride'] || c['summary']
    }
  end

  # Calculate start and end of next month
  current_date = Date.today
  next_month_date = current_date.next_month

  first_of_next_month = Date.new(next_month_date.year, next_month_date.month, 1)
  last_of_next_month = Date.new(next_month_date.year, next_month_date.month, -1)

  time_min = Time.local(first_of_next_month.year, first_of_next_month.month, 1, 0, 0, 0)
  time_max = Time.local(last_of_next_month.year, last_of_next_month.month, last_of_next_month.day, 23, 59, 59)

  month_name = first_of_next_month.strftime('%B %Y')
  if calendar_name
    cal_title = selected_calendars.first['summaryOverride'] || selected_calendars.first['summary']
    shortcut = aliases[selected_calendars.first['id']] || cal_title
    puts Rainbow("Schedule for '#{shortcut}' in #{month_name}:").bold.underline.cyan
  else
    puts Rainbow("Schedule for Next Month in #{month_name} (All Selected Calendars):").bold.underline.cyan
  end
  puts

  cached_events_by_calendar = get_cached_calendar_events(access_token)
  all_events = []
  selected_calendars.each do |c|
    events = cached_events_by_calendar[c['id']] || []
    events.each do |event|
      event['_calendar_id'] = c['id']
      all_events << event
    end
  end

  color_assignments = get_calendar_colors(selected_calendars)

  parsed_events = all_events.map do |event|
    times = parse_event_time(event)
    {
      event: event,
      start_time: times[:start_time],
      end_time: times[:end_time],
      all_day: times[:all_day],
      calendar_id: event['_calendar_id'],
      calendar_summary: calendar_map[event['_calendar_id']][:shortcut],
      priority: parse_priority(event['description'])
    }
  end

  parsed_events = parsed_events.select do |pe|
    pe[:start_time] >= time_min && pe[:start_time] <= time_max
  end

  events_by_day = parsed_events.group_by { |pe| pe[:start_time].to_date }

  has_events = false
  (first_of_next_month..last_of_next_month).each do |day_date|
    day_events = events_by_day[day_date] || []

    next if day_events.empty?
    has_events = true

    day_name = day_date.strftime("%A, %B %d")
    border_prefix = "┌── #{day_name} "
    padding_dashes = [0, 80 - border_prefix.length].max
    puts Rainbow(border_prefix + "─" * padding_dashes).bold.yellow

    sorted_events = day_events.sort_by do |pe|
      [pe[:all_day] ? 0 : 1, pe[:start_time], pe[:end_time], pe[:event]['summary'] || ""]
    end

    sorted_events.each do |pe|
      summary = pe[:event]['summary'] || "(No Title)"

      if pe[:all_day]
        time_str = "All Day"
      else
        time_str = "#{pe[:start_time].strftime('%H:%M')} - #{pe[:end_time].strftime('%H:%M')}"
      end

      cal_color = color_assignments[pe[:calendar_id]] || :default
      render_event_line(time_str, pe[:calendar_summary], cal_color, summary, pe[:priority], show_id, pe[:event]['_friendly_id'], show_recurrence, pe[:event]['_recurrence_freq'])

      desc = pe[:event]['description']
      if desc && !desc.strip.empty?
        desc_lines = desc.strip.split("\n").reject { |line| line =~ /^\s*priority:\s*-?\d+(?:\.\d+)?\s*$/i }
        first_desc_line = desc_lines.first
        if first_desc_line && !first_desc_line.strip.empty?
          puts "│      " + Rainbow(first_desc_line).color(128, 128, 128).italic
        end
      end
    end
    puts
  end

  unless has_events
    puts Rainbow("No events scheduled for #{month_name}!").yellow
  end
end

# Command: year [calendar]
def show_year_schedule(access_token, calendar_name = nil, show_id = false, show_recurrence = false)
  all_calendars = get_cached_calendar_list(access_token)
  aliases = load_aliases

  if calendar_name
    cal = resolve_calendar(access_token, calendar_name)
    unless cal
      puts Rainbow("Error: Calendar '#{calendar_name}' not found.").red.bright
      exit 1
    end
    selected_calendars = [cal]
  else
    selected_calendars = all_calendars.select { |c| c['selected'] }
    if selected_calendars.empty?
      primary = all_calendars.find { |c| c['primary'] } || all_calendars.first
      selected_calendars = [primary].compact
    end
  end

  calendar_map = {}
  selected_calendars.each do |c|
    calendar_map[c['id']] = {
      summary: c['summaryOverride'] || c['summary']
    }
  end

  color_assignments = get_calendar_colors(selected_calendars)
  cached_events_by_calendar = get_cached_calendar_events(access_token)

  year = Time.now.year
  time_min = Time.local(year, 1, 1, 0, 0, 0)
  time_max = Time.local(year, 12, 31, 23, 59, 59)

  all_events = []
  selected_calendars.each do |c|
    events = cached_events_by_calendar[c['id']] || []
    events.each do |event|
      times = parse_event_time(event)
      if times[:start_time] >= time_min && times[:start_time] <= time_max
        event['_calendar_id'] = c['id']
        event['_calendar_summary'] = calendar_map[c['id']][:summary]
        all_events << {
          event: event,
          start_time: times[:start_time],
          end_time: times[:end_time],
          all_day: times[:all_day],
          calendar_id: c['id'],
          calendar_summary: calendar_map[c['id']][:summary],
          priority: parse_priority(event['description']),
          recurrence_freq: event['_recurrence_freq']
        }
      end
    end
  end

  # Display header
  if calendar_name
    cal_title = selected_calendars.first['summaryOverride'] || selected_calendars.first['summary']
    puts Rainbow("Yearly Schedule for #{year} - #{cal_title}").bold.underline.cyan
  else
    puts Rainbow("Yearly Schedule for #{year} (All Selected Calendars)").bold.underline.cyan
  end
  puts

  if all_events.empty?
    puts Rainbow("No events scheduled for #{year}.").yellow
    return
  end

  all_events.sort_by! { |e| [e[:start_time], e[:all_day] ? 0 : 1] }

  all_events.each do |e|
    if e[:all_day]
      date_str = e[:start_time].strftime('%Y-%m-%d') + " All Day"
    else
      start_day_str = e[:start_time].strftime('%Y-%m-%d')
      end_day_str = e[:end_time].strftime('%Y-%m-%d')
      if start_day_str == end_day_str
        date_str = "#{start_day_str} #{e[:start_time].strftime('%H:%M')}-#{e[:end_time].strftime('%H:%M')}"
      else
        date_str = "#{start_day_str} #{e[:start_time].strftime('%H:%M')} to #{e[:end_time].strftime('%m-%d %H:%M')}"
      end
    end

    cal_str = "[#{aliases[e[:calendar_id]] || e[:calendar_summary]}]"
    id_tag = show_id && e[:event]['_friendly_id'] ? "[#{e[:event]['_friendly_id']}] " : ""
    rec_tag = show_recurrence && e[:recurrence_freq] ? "(⟲ #{e[:recurrence_freq]}) " : ""
    summary = e[:event]['summary'] || "(No Title)"

    if e[:priority]
      prio_str = (e[:priority] % 1 == 0) ? " #{e[:priority].to_i}" : " #{sprintf('%.1f', e[:priority])}"
      colored_prio = format_priority_rainbow(prio_str, e[:priority])
    else
      prio_str = ""
      colored_prio = ""
    end

    # Calculate padding for exactly 80 characters boundary alignment
    available_width = 80 - 25 - 1 - 12 - 1 - id_tag.length - rec_tag.length - prio_str.length
    truncated_summary = summary.length > available_width ? summary[0...[0, available_width - 3].max] + "..." : summary
    padding = " " * [0, available_width - truncated_summary.length].max

    puts sprintf("%s %s %s%s%s%s%s",
                 Rainbow(date_str.ljust(25)).green,
                 Rainbow(sprintf("%-12s", cal_str)).color(color_assignments[e[:calendar_id]]),
                 Rainbow(id_tag).color(128, 128, 128),
                 Rainbow(rec_tag).color(0, 128, 128).italic,
                 Rainbow(truncated_summary).bold,
                 padding,
                 colored_prio)
  end
  puts
end

# Invalidates the local calendar events cache
def invalidate_cache
  File.delete(CACHE_FILE) if File.exist?(CACHE_FILE)
end

# Fetches the remote updated timestamp for a single calendar
def fetch_calendar_update_time(access_token, calendar_id)
  uri = URI("https://www.googleapis.com/calendar/v3/calendars/#{ERB::Util.url_encode(calendar_id)}/events?maxResults=1&fields=updated")
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{access_token}"

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  res = http.request(req)
  return nil unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)['updated']
end

# Fetches remote updated timestamps for all calendars concurrently using threads
def fetch_all_calendar_update_times(access_token, calendar_ids)
  threads = []
  results = {}
  mutex = Mutex.new

  calendar_ids.each do |calendar_id|
    threads << Thread.new do
      updated = fetch_calendar_update_time(access_token, calendar_id)
      mutex.synchronize { results[calendar_id] = updated }
    end
  end

  threads.each(&:join)
  results
end

# Helper to fetch a specific master event to get its recurrence rules
def fetch_master_event(access_token, calendar_id, event_id)
  uri = URI("https://www.googleapis.com/calendar/v3/calendars/#{ERB::Util.url_encode(calendar_id)}/events/#{ERB::Util.url_encode(event_id)}")
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{access_token}"

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  res = http.request(req)
  return nil unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end

CONFIG_FILE = File.join(CONFIG_DIR, "config.json") unless defined?(CONFIG_FILE)

def load_config
  if File.exist?(CONFIG_FILE)
    begin
      JSON.parse(File.read(CONFIG_FILE))
    rescue
      {}
    end
  else
    {}
  end
end

def save_config(config)
  File.write(CONFIG_FILE, JSON.generate(config))
end

def show_detailed_help(command)
  case command
  when 'list'
    puts Rainbow("Command: list").bold.cyan
    puts "  Displays all accessible calendars from Google Calendar, showing their roles,"
    puts "  selection status, and configured aliases."
    puts "  Usage: ./my_cal list"
  when 'today'
    puts Rainbow("Command: today").bold.cyan
    puts "  Shows your schedule for today and tomorrow."
    puts "  Usage: ./my_cal today [-i] [-r]"
    puts "  Flags:"
    puts "    -i : Print user-friendly sequential event IDs"
    puts "    -r : Print recurrence frequency tags"
  when 'next'
    puts Rainbow("Command: next").bold.cyan
    puts "  Finds and displays the closest active or future upcoming event."
    puts "  Includes a live countdown timer."
    puts "  Usage: ./my_cal next [-i]"
    puts "  Flags:"
    puts "    -i : Print user-friendly event ID"
  when 'week'
    puts Rainbow("Command: week").bold.cyan
    puts "  Shows a weekly schedule starting from Monday through Sunday."
    puts "  Usage: ./my_cal week [cal-name] [-i] [-r]"
    puts "  Arguments:"
    puts "    [cal-name] : Optional calendar name or alias to filter strictly"
    puts "  Flags:"
    puts "    -i : Print user-friendly event IDs"
    puts "    -r : Print recurrence frequency tags"
  when 'month'
    puts Rainbow("Command: month").bold.cyan
    puts "  Shows next calendar month's schedule."
    puts "  Usage: ./my_cal month [cal-name] [-i] [-r]"
    puts "  Arguments:"
    puts "    [cal-name] : Optional calendar name or alias to filter strictly"
    puts "  Flags:"
    puts "    -i : Print user-friendly event IDs"
    puts "    -r : Print recurrence frequency tags"
  when 'year'
    puts Rainbow("Command: year").bold.cyan
    puts "  Shows all events for the current year in a compact, single-line format."
    puts "  Usage: ./my_cal year [cal-name] [-i] [-r]"
    puts "  Arguments:"
    puts "    [cal-name] : Optional calendar name or alias to filter strictly"
    puts "  Flags:"
    puts "    -i : Print user-friendly event IDs"
    puts "    -r : Print recurrence frequency tags"
  when 'alias'
    puts Rainbow("Command: alias").bold.cyan
    puts "  Binds a short alias/shortcut to a calendar for quick reference."
    puts "  Usage: ./my_cal alias <name> <shortcut>"
    puts "  To remove an alias, pass empty quotes: ./my_cal alias <name> \"\""
  when 'add_priority'
    puts Rainbow("Command: add_priority").bold.cyan
    puts "  Scans future events in the specified calendar and appends a default"
    puts "  priority of 5.0 to descriptions of events that don't have one."
    puts "  Usage: ./my_cal add_priority <cal-name>"
  when 'del_event'
    puts Rainbow("Command: del_event").bold.cyan
    puts "  Deletes an event from your calendar using its friendly ID."
    puts "  Usage: ./my_cal del_event <friendly-id>"
  when 'web'
    puts Rainbow("Command: web").bold.cyan
    puts "  Opens the specified event in your default browser for remote editing."
    puts "  Usage: ./my_cal web <friendly-id>"
  when 'merge'
    puts Rainbow("Command: merge").bold.cyan
    puts "  Combines two duplicate events into a single event."
    puts "  Events must occur at the exact same time and have identical recurrence rules."
    puts "  Usage: ./my_cal merge <id1> <id2>"
  when 'search'
    puts Rainbow("Command: search").bold.cyan
    puts "  Performs sequential keyword search across all calendars."
    puts "  Usage: ./my_cal search <word> [-i] [-r]"
  when 'search_week', 'search_month', 'search_year'
    puts Rainbow("Command: #{command}").bold.cyan
    puts "  Searches all calendars for the keyword within this week, month, or year."
    puts "  Usage: ./my_cal #{command} <word> [-i] [-r]"
  when 'reload'
    puts Rainbow("Command: reload").bold.cyan
    puts "  Explicitly clears and reloads the local cache from Google Calendar servers."
    puts "  Usage: ./my_cal reload"
  when 'default'
    puts Rainbow("Command: default").bold.cyan
    puts "  Sets the persistent default calendar for quick event addition."
    puts "  Usage: ./my_cal default <cal-name-or-id>"
  when 'add'
    puts Rainbow("Command: add").bold.cyan
    puts "  Quick-adds an event to your default calendar using natural language."
    puts "  Usage: ./my_cal add \"<natural-language-text>\""
    puts "  Example: ./my_cal add \"Dentist appointment tomorrow at 3pm\""
  when 'add-full'
    puts Rainbow("Command: add-full").bold.cyan
    puts "  Creates a fully configured event in the specified calendar."
    puts "  Usage: ./my_cal add-full <cal-name> <summary> <start-time> <end-time> [description] [location]"
    puts "  Example: ./my_cal add-full Personal \"Lunch with Ben\" \"2026-05-27 12:00\" \"2026-05-27 13:00\" \"Discuss project\" \"Cafe\""
  else
    puts Rainbow("Unknown command: #{command}").red.bright
  end
  puts
end

def print_general_usage
  puts Rainbow("Usage:").bold.cyan
  puts "  ./my_cal [interactive] [-i] [-r] - Show interactive side-by-side month/schedule TUI (default)"
  puts "  ./my_cal list                    - Show all calendars and status (including aliases)"
  puts "  ./my_cal today [-i] [-r]         - Show schedule for today and tomorrow"
  puts "  ./my_cal next [-i]               - Show the next upcoming/active event with countdown"
  puts "  ./my_cal week [cal-name] [-i][-r]- Show this week's events (pass -i for IDs, -r for recurrence)"
  puts "  ./my_cal month [cal-name] [-i][-r]- Show next month's events"
  puts "  ./my_cal year [cal-name] [-i][-r]- Show all events in calendar for a year in a compact single-line layout"
  puts "  ./my_cal alias <name> <alias>    - Set an alias/shortcut for a calendar"
  puts "  ./my_cal alias <name> \"\"         - Remove an alias/shortcut for a calendar"
  puts "  ./my_cal add_priority <cal-name> - Add default priority 5.0 to future events lacking priority"
  puts "  ./my_cal del_event <id>          - Delete an event by its user-friendly ID"
  puts "  ./my_cal web <id>                - Open an event in the web browser for editing"
  puts "  ./my_cal merge <id1> <id2>       - Merge two events at the same time and recurrence"
  puts "  ./my_cal search <word> [-i] [-r] - Search all calendars sequentially for first hit"
  puts "  ./my_cal search_week <word> [-i][-r]- Search all calendars for all hits this week"
  puts "  ./my_cal search_month <word> [-i][-r]- Search all calendars for all hits this month"
  puts "  ./my_cal search_year <word> [-i][-r]- Search all calendars for all hits this year"
  puts "  ./my_cal reload                  - Explicitly reload and refresh the local calendar cache"
  puts "  ./my_cal default <cal-name>      - Set the default calendar persistently"
  puts "  ./my_cal add \"<text>\"             - Quick-add an event to the default calendar using natural language"
  puts "  ./my_cal add-full <cal> <sum> <start> <end> [desc] [loc] - Create a full event in a calendar"
  puts "  Note: Append '?' to any command to see detailed help (e.g. ./my_cal add '?')"
end

def set_default_calendar(access_token, calendar_name)
  cal = resolve_calendar(access_token, calendar_name)
  unless cal
    puts Rainbow("Error: Calendar '#{calendar_name}' not found.").red.bright
    exit 1
  end
  config = load_config
  config['default_calendar_id'] = cal['id']
  save_config(config)
  real_name = cal['summaryOverride'] || cal['summary']
  puts Rainbow("Default calendar set to '#{real_name}' (ID: #{cal['id']}).").green
end

def quick_add_event(access_token, text)
  config = load_config
  calendar_id = config['default_calendar_id']
  if calendar_id.nil? || calendar_id.empty?
    all_calendars = get_cached_calendar_list(access_token)
    primary = all_calendars.find { |c| c['primary'] } || all_calendars.first
    calendar_id = primary ? primary['id'] : 'primary'
  end

  uri = URI("https://www.googleapis.com/calendar/v3/calendars/#{CGI.escape(calendar_id)}/events/quickAdd?text=#{CGI.escape(text)}&sendUpdates=none")
  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Bearer #{access_token}"

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  res = http.request(req)
  unless res.is_a?(Net::HTTPSuccess)
    raise "Failed to quick add event: #{res.code} - #{res.body}"
  end

  event = JSON.parse(res.body)
  summary = event['summary'] || "(No Title)"
  start_time = event['start'] ? (event['start']['dateTime'] || event['start']['date']) : "unknown"
  
  update_local_cache_for_calendar(access_token, calendar_id)

  puts Rainbow("Quick-added event '#{summary}' (starts: #{start_time}) to calendar.").green
end

def add_full_event(access_token, calendar_name, summary, start_time_str, end_time_str, description = nil, location = nil)
  cal = resolve_calendar(access_token, calendar_name)
  unless cal
    puts Rainbow("Error: Calendar '#{calendar_name}' not found.").red.bright
    exit 1
  end

  begin
    start_t = Time.parse(start_time_str)
    end_t = Time.parse(end_time_str)
  rescue => e
    puts Rainbow("Error parsing times: #{e.message}. Please use formats like 'YYYY-MM-DD HH:MM' or 'HH:MM'.").red.bright
    exit 1
  end

  payload = {
    'summary' => summary,
    'start' => { 'dateTime' => start_t.iso8601 },
    'end' => { 'dateTime' => end_t.iso8601 }
  }
  payload['description'] = description if description && !description.empty?
  payload['location'] = location if location && !location.empty?

  uri = URI("https://www.googleapis.com/calendar/v3/calendars/#{CGI.escape(cal['id'])}/events?sendUpdates=none")
  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Bearer #{access_token}"
  req['Content-Type'] = "application/json"
  req.body = JSON.generate(payload)

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  res = http.request(req)
  unless res.is_a?(Net::HTTPSuccess)
    raise "Failed to add event: #{res.code} - #{res.body}"
  end

  update_local_cache_for_calendar(access_token, cal['id'])

  puts Rainbow("Successfully added event '#{summary}' to calendar '#{cal['summaryOverride'] || cal['summary']}'!").green
end

# Helper to parse recurrence frequency from rrule array
def parse_recurrence_frequency(recurrence_array)
  return nil if recurrence_array.nil? || recurrence_array.empty?
  rrule = recurrence_array.find { |r| r.start_with?("RRULE:") }
  return "Recurring" if rrule.nil?
  
  if rrule =~ /FREQ=([A-Z]+)/
    return $1.capitalize # e.g. "Weekly", "Daily", "Monthly", "Yearly"
  end
  "Recurring"
end

# Downloads all calendars and their events concurrently using threads, saving to local cache
def reload_calendar_cache(access_token)
  puts Rainbow("Downloading remote calendars into local cache...").cyan
  all_calendars = fetch_calendar_list(access_token)
  
  # Fetch events for each calendar from 30 days ago to 365 days in the future
  time_min = Time.now - 30 * 86400
  time_max = Time.now + 365 * 86400

  events_by_calendar = {}
  calendar_updates = {}
  
  threads = []
  mutex = Mutex.new
  
  all_calendars.each do |cal|
    threads << Thread.new do
      begin
        events = fetch_calendar_events(access_token, cal['id'], time_min, time_max)
        updated = fetch_calendar_update_time(access_token, cal['id'])
        mutex.synchronize do
          events_by_calendar[cal['id']] = events
          calendar_updates[cal['id']] = updated
        end
      rescue => e
        warn Rainbow("Warning: Failed to cache events for #{cal['id']}: #{e.message}").yellow
        mutex.synchronize do
          events_by_calendar[cal['id']] = []
          calendar_updates[cal['id']] = nil
        end
      end
    end
  end
  
  threads.each(&:join)

  # Collect all unique recurringEventId values across all calendars
  all_recurring_ids = []
  events_by_calendar.each do |cal_id, events|
    events.each do |event|
      if event['recurringEventId']
        all_recurring_ids << [cal_id, event['recurringEventId']]
      end
    end
  end
  all_recurring_ids.uniq!

  # Concurrently fetch master events to retrieve their recurrence rules
  recurrence_rules = {}
  rec_mutex = Mutex.new
  rec_threads = []

  all_recurring_ids.each do |cal_id, parent_id|
    rec_threads << Thread.new do
      begin
        master = fetch_master_event(access_token, cal_id, parent_id)
        if master && master['recurrence']
          rec_mutex.synchronize do
            recurrence_rules[parent_id] = master['recurrence']
          end
        end
      rescue
      end
    end
  end
  rec_threads.each(&:join)

  cache_data = {
    'last_download_at' => Time.now.to_i,
    'calendar_list' => all_calendars,
    'calendar_updates' => calendar_updates,
    'events_by_calendar' => events_by_calendar,
    'recurrence_rules' => recurrence_rules
  }

  File.write(CACHE_FILE, JSON.generate(cache_data))
  puts Rainbow("Calendar cache successfully reloaded!").green
end

# Populates in-memory sequential user-friendly event IDs and recurrence frequencies
def populate_friendly_ids!(events_by_calendar, calendar_list, recurrence_rules = {})
  cal_ids = (calendar_list || []).map { |c| c['id'] }
  cal_ids = events_by_calendar.keys if cal_ids.empty?

  friendly_id = 1
  cal_ids.uniq.each do |cal_id|
    events = events_by_calendar[cal_id] || []
    events.each do |event|
      event['_friendly_id'] = friendly_id
      friendly_id += 1

      if event['recurringEventId']
        rrule_array = recurrence_rules[event['recurringEventId']]
        event['_recurrence_freq'] = parse_recurrence_frequency(rrule_array)
      else
        event['_recurrence_freq'] = nil
      end
    end
  end
end

# Loads calendar events from local cache, performing concurrent smart update check
def get_cached_calendar_events(access_token, force = false)
  if !force && File.exist?(CACHE_FILE)
    begin
      cache = JSON.parse(File.read(CACHE_FILE))
      last_download = cache['last_download_at'] || 0
      cached_updates = cache['calendar_updates'] || {}

      # Fast path: If verified/updated within the last 5 minutes, use cache instantly without network checks
      if Time.now.to_i - last_download < 300
        events_by_cal = cache['events_by_calendar']
        populate_friendly_ids!(events_by_cal, cache['calendar_list'], cache['recurrence_rules'] || {})
        return events_by_cal
      end

      # Otherwise, perform concurrent check of remote update times
      all_calendars = fetch_calendar_list(access_token)
      selected_ids = all_calendars.map { |c| c['id'] }
      
      remote_updates = fetch_all_calendar_update_times(access_token, selected_ids)
      
      cache_stale = false
      selected_ids.each do |cal_id|
        if remote_updates[cal_id] != cached_updates[cal_id]
          cache_stale = true
          break
        end
      end

      if !cache_stale
        # Update last_download_at to extend the 5-minute fast-path window
        cache['last_download_at'] = Time.now.to_i
        File.write(CACHE_FILE, JSON.generate(cache)) rescue nil
        events_by_cal = cache['events_by_calendar']
        populate_friendly_ids!(events_by_cal, cache['calendar_list'], cache['recurrence_rules'] || {})
        return events_by_cal
      end
    rescue => e
      # Ignore corruption or network check errors, reload cache
    end
  end

  # Cache does not exist, is stale, or force is true
  reload_calendar_cache(access_token)
  
  begin
    cache = JSON.parse(File.read(CACHE_FILE))
    events_by_cal = cache['events_by_calendar']
    populate_friendly_ids!(events_by_cal, cache['calendar_list'], cache['recurrence_rules'] || {})
    return events_by_cal
  rescue => e
    raise "Failed to load events from cache: #{e.message}"
  end
end

# Returns the cached calendar list, checking cache validity first
def get_cached_calendar_list(access_token)
  get_cached_calendar_events(access_token)
  begin
    cache = JSON.parse(File.read(CACHE_FILE))
    return cache['calendar_list'] || []
  rescue => e
    return []
  end
end

# Updates the local cache in-place for only the specified calendar
def update_local_cache_for_calendar(access_token, calendar_id)
  return unless File.exist?(CACHE_FILE)

  begin
    cache = JSON.parse(File.read(CACHE_FILE))
    events_by_calendar = cache['events_by_calendar'] || {}
    calendar_updates = cache['calendar_updates'] || {}
    recurrence_rules = cache['recurrence_rules'] || {}

    # Query only this specific calendar's events (30 days ago to 365 days in future)
    time_min = Time.now - 30 * 86400
    time_max = Time.now + 365 * 86400

    events = fetch_calendar_events(access_token, calendar_id, time_min, time_max)
    updated = fetch_calendar_update_time(access_token, calendar_id)

    # Fetch recurrence rules for any new recurring events in this calendar
    recurring_ids = events.map { |e| e['recurringEventId'] }.compact.uniq
    
    rec_threads = []
    rec_mutex = Mutex.new
    
    recurring_ids.each do |parent_id|
      next if recurrence_rules.has_key?(parent_id)
      rec_threads << Thread.new do
        begin
          master = fetch_master_event(access_token, calendar_id, parent_id)
          if master && master['recurrence']
            rec_mutex.synchronize do
              recurrence_rules[parent_id] = master['recurrence']
            end
          end
        rescue
        end
      end
    end
    rec_threads.each(&:join)

    events_by_calendar[calendar_id] = events
    calendar_updates[calendar_id] = updated
    cache['recurrence_rules'] = recurrence_rules

    cache['last_download_at'] = Time.now.to_i
    cache['events_by_calendar'] = events_by_calendar
    cache['calendar_updates'] = calendar_updates

    File.write(CACHE_FILE, JSON.generate(cache))
  rescue => e
    # Fallback to invalidating the cache if in-place refresh fails
    invalidate_cache
  end
end

# Helper to patch an event on the remote Google Calendar
def patch_calendar_event(access_token, calendar_id, event_id, payload)
  uri = URI("https://www.googleapis.com/calendar/v3/calendars/#{ERB::Util.url_encode(calendar_id)}/events/#{event_id}?sendUpdates=none")
  req = Net::HTTP::Patch.new(uri)
  req['Authorization'] = "Bearer #{access_token}"
  req['Content-Type'] = "application/json"
  req.body = JSON.generate(payload)

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  res = http.request(req)
  unless res.is_a?(Net::HTTPSuccess)
    raise "Failed to update event #{event_id}: #{res.code} - #{res.body}"
  end
  update_local_cache_for_calendar(access_token, calendar_id)
  JSON.parse(res.body)
end

# Command: add_priority
def add_priority_to_future_events(access_token, calendar_name)
  cal = resolve_calendar(access_token, calendar_name)
  unless cal
    raise "Calendar '#{calendar_name}' not found."
  end

  aliases = load_aliases
  real_name = cal['summaryOverride'] || cal['summary']
  shortcut = aliases[cal['id']] || real_name

  # Scan for future events from now up to the end of the next calendar month
  time_min = Time.now
  current_date = Date.today
  next_month_date = current_date.next_month
  last_of_next_month = Date.new(next_month_date.year, next_month_date.month, -1)
  time_max = Time.local(last_of_next_month.year, last_of_next_month.month, last_of_next_month.day, 23, 59, 59)

  puts Rainbow("Scanning for future events in '#{shortcut}' until #{last_of_next_month.strftime('%B %d, %Y')}...").cyan
  puts

  events = fetch_calendar_events(access_token, cal['id'], time_min, time_max)

  if events.empty?
    puts Rainbow("No future events found to update.").yellow
    return
  end

  updated_count = 0
  skipped_count = 0

  events.each do |event|
    summary = event['summary'] || "(No Title)"
    description = event['description'] || ""

    if event['eventType'] == 'birthday'
      puts sprintf("  %s  %s (birthday event type cannot have description)", Rainbow("Skipping:").yellow, Rainbow(summary).bold)
      skipped_count += 1
      next
    end

    # Check if notes have "priority: <number>" on a line start
    if description =~ /^priority:\s*\d+(\.\d+)?/i
      puts sprintf("  %s  %s (already has priority in description)", Rainbow("Skipping:").yellow, Rainbow(summary).bold)
      skipped_count += 1
    else
      new_description = description.empty? ? "priority: 5.0" : description.rstrip + "\npriority: 5.0"

      begin
        # Perform PATCH request
        patch_calendar_event(access_token, cal['id'], event['id'], { 'description' => new_description })
        puts sprintf("  %s   %s (added priority: 5.0)", Rainbow("Updated:").green, Rainbow(summary).bold)
        updated_count += 1
      rescue => e
        puts sprintf("  %s     Failed to update event '%s': %s", Rainbow("Error:").red.bright, Rainbow(summary).bold, e.message)
        skipped_count += 1
      end
    end
  end

  puts
  puts Rainbow("Scan and update complete!").bold.cyan
  puts "  Updated: #{updated_count} events"
  puts "  Skipped: #{skipped_count} events"
end

# Helper to delete an event from the remote Google Calendar
def delete_calendar_event(access_token, calendar_id, event_id)
  uri = URI("https://www.googleapis.com/calendar/v3/calendars/#{ERB::Util.url_encode(calendar_id)}/events/#{event_id}?sendUpdates=none")
  req = Net::HTTP::Delete.new(uri)
  req['Authorization'] = "Bearer #{access_token}"

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  res = http.request(req)
  unless res.is_a?(Net::HTTPSuccess)
    raise "Failed to delete event #{event_id}: #{res.code} - #{res.body}"
  end
  update_local_cache_for_calendar(access_token, calendar_id)
  true
end

# Command: del_event
def delete_event_by_friendly_id(access_token, friendly_id_str)
  friendly_id = friendly_id_str.to_i
  if friendly_id <= 0
    puts Rainbow("Error: Please provide a positive integer for the event ID.").red.bright
    exit 1
  end

  events_by_calendar = get_cached_calendar_events(access_token)
  all_calendars = get_cached_calendar_list(access_token)
  
  matched_event = nil
  cal_id = nil
  events_by_calendar.each do |c_id, events|
    events.each do |event|
      if event['_friendly_id'] == friendly_id
        matched_event = event
        cal_id = c_id
        break
      end
    end
    break if matched_event
  end

  if matched_event.nil?
    puts Rainbow("Error: Event with ID #{friendly_id} not found.").red.bright
    exit 1
  end

  summary = matched_event['summary'] || "(No Title)"
  cal = all_calendars.find { |c| c['id'] == cal_id }
  cal_name = cal ? (cal['summaryOverride'] || cal['summary']) : "Unknown"

  # Perform DELETE request
  delete_calendar_event(access_token, cal_id, matched_event['id'])

  puts Rainbow("Deleted event '#{summary}' (ID: #{friendly_id}) from calendar '#{cal_name}'.").green
end

# Checks if event summary or description matches the search term (case-insensitive)
def event_matches?(event, word)
  word_down = word.downcase
  summary = (event['summary'] || "").downcase
  description = (event['description'] || "").downcase
  summary.include?(word_down) || description.include?(word_down)
end

# Renders a single search match inside a standard 80-character box
def render_single_search_hit(hit, color_assignments, show_id, show_recurrence = false)
  puts Rainbow("Matching Event Found:").bold.green
  puts
  
  day_date = hit[:start_time].to_date
  day_name = day_date.strftime("%A, %B %d")
  border_prefix = "┌── #{day_name} "
  padding_dashes = [0, 80 - border_prefix.length].max
  puts Rainbow(border_prefix + "─" * padding_dashes).bold.yellow

  summary = hit[:event]['summary'] || "(No Title)"
  cal_summary = hit[:calendar_summary]
  cal_color = color_assignments[hit[:calendar_id]] || :default

  if hit[:all_day]
    time_str = "All Day"
  else
    time_str = "#{hit[:start_time].strftime('%H:%M')} - #{hit[:end_time].strftime('%H:%M')}"
  end

  render_event_line(time_str, cal_summary, cal_color, summary, hit[:priority], show_id, hit[:event]['_friendly_id'], show_recurrence, hit[:event]['_recurrence_freq'])

  desc = hit[:event]['description']
  if desc && !desc.strip.empty?
    desc_lines = desc.strip.split("\n").reject { |line| line =~ /^\s*priority:\s*-?\d+(?:\.\d+)?\s*$/i }
    first_desc_line = desc_lines.first
    if first_desc_line && !first_desc_line.strip.empty?
      puts "│      " + Rainbow(first_desc_line).color(128, 128, 128).italic
    end
  end
  
  puts "└" + "─" * 79
  puts
end

# Renders multiple search hits grouped by day
def render_multiple_search_hits(hits, color_assignments, show_id, show_recurrence = false)
  events_by_day = hits.group_by { |h| h[:start_time].to_date }

  events_by_day.keys.sort.each do |day_date|
    day_name = day_date.strftime("%A, %B %d")
    border_prefix = "┌── #{day_name} "
    padding_dashes = [0, 80 - border_prefix.length].max
    puts Rainbow(border_prefix + "─" * padding_dashes).bold.yellow

    day_events = events_by_day[day_date]
    day_events.each do |hit|
      summary = hit[:event]['summary'] || "(No Title)"
      cal_summary = hit[:calendar_summary]
      cal_color = color_assignments[hit[:calendar_id]] || :default

      if hit[:all_day]
        time_str = "All Day"
      else
        time_str = "#{hit[:start_time].strftime('%H:%M')} - #{hit[:end_time].strftime('%H:%M')}"
      end

      render_event_line(time_str, cal_summary, cal_color, summary, hit[:priority], show_id, hit[:event]['_friendly_id'], show_recurrence, hit[:event]['_recurrence_freq'])

      desc = hit[:event]['description']
      if desc && !desc.strip.empty?
        desc_lines = desc.strip.split("\n").reject { |line| line =~ /^\s*priority:\s*-?\d+(?:\.\d+)?\s*$/i }
        first_desc_line = desc_lines.first
        if first_desc_line && !first_desc_line.strip.empty?
          puts "│      " + Rainbow(first_desc_line).color(128, 128, 128).italic
        end
      end
    end
    puts "└" + "─" * 79
    puts
  end
end

# Command: search / search_week / search_month / search_year
# Command: search / search_week / search_month / search_year
def perform_calendar_search(access_token, word, scope, show_id = false, show_recurrence = false)
  aliases = load_aliases
  all_calendars = fetch_calendar_list(access_token)
  
  # Group color assignments
  color_assignments = get_calendar_colors(all_calendars)

  today = Date.today
  today_min = Time.local(today.year, today.month, today.day, 0, 0, 0)
  today_max = Time.local(today.year, today.month, today.day, 23, 59, 59)

  days_since_monday = (today.wday - 1) % 7
  monday = today - days_since_monday
  sunday = monday + 6
  week_min = Time.local(monday.year, monday.month, monday.day, 0, 0, 0)
  week_max = Time.local(sunday.year, sunday.month, sunday.day, 23, 59, 59)

  first_of_month = Date.new(today.year, today.month, 1)
  last_of_month = Date.new(today.year, today.month, -1)
  month_min = Time.local(first_of_month.year, first_of_month.month, 1, 0, 0, 0)
  month_max = Time.local(last_of_month.year, last_of_month.month, last_of_month.day, 23, 59, 59)

  year_min = today_min
  year_max = today_min + 365 * 86400

  # Helper to query a specific time range and search events locally from cache
  search_range = lambda do |t_min, t_max|
    hits = []
    cached_events_by_calendar = get_cached_calendar_events(access_token)
    
    all_calendars.each do |cal|
      events = cached_events_by_calendar[cal['id']] || []
      events.each do |event|
        if event_matches?(event, word)
          times = parse_event_time(event)
          # Filter locally for time range bounds
          if times[:start_time] >= t_min && times[:start_time] <= t_max
            hits << {
              event: event,
              start_time: times[:start_time],
              end_time: times[:end_time],
              all_day: times[:all_day],
              calendar_id: cal['id'],
              calendar_summary: aliases[cal['id']] || cal['summaryOverride'] || cal['summary'],
              priority: parse_priority(event['description'])
            }
          end
        end
      end
    end
    # Sort chronologically
    hits.sort_by { |h| [h[:start_time], h[:event]['summary'] || ""] }
  end

  if scope == :all_sequential
    # Search Today
    hits = search_range.call(today_min, today_max)
    if !hits.empty?
      render_single_search_hit(hits.first, color_assignments, show_id, show_recurrence)
      return
    end

    # Search Week
    hits = search_range.call(week_min, week_max)
    if !hits.empty?
      render_single_search_hit(hits.first, color_assignments, show_id, show_recurrence)
      return
    end

    # Search Month
    hits = search_range.call(month_min, month_max)
    if !hits.empty?
      render_single_search_hit(hits.first, color_assignments, show_id, show_recurrence)
      return
    end

    # Search Year Forward
    hits = search_range.call(year_min, year_max)
    if !hits.empty?
      render_single_search_hit(hits.first, color_assignments, show_id, show_recurrence)
      return
    end

    puts Rainbow("No matching event found for '#{word}' in today, week, month, or year forward.").yellow
  else
    # Explicit range search, listing all hits
    t_min, t_max, label = case scope
                          when :week then [week_min, week_max, "this week"]
                          when :month then [month_min, month_max, "this month"]
                          when :year then [year_min, year_max, "this year"]
                          end

    puts Rainbow("Searching all calendars for '#{word}' in #{label}...").cyan
    hits = search_range.call(t_min, t_max)
    
    if hits.empty?
      puts Rainbow("No matching events found.").yellow
      return
    end

    render_multiple_search_hits(hits, color_assignments, show_id, show_recurrence)
  end
end

# Command: web <id>
def open_event_in_browser(access_token, id_str)
  id = id_str.to_i
  if id <= 0
    puts Rainbow("Error: Please provide a positive integer for the event ID.").red.bright
    exit 1
  end

  events_by_calendar = get_cached_calendar_events(access_token)
  
  matched_event = nil
  events_by_calendar.each do |cal_id, events|
    events.each do |event|
      if event['_friendly_id'] == id
        matched_event = event
        break
      end
    end
    break if matched_event
  end

  if matched_event.nil?
    puts Rainbow("Error: Event with ID #{id} not found.").red.bright
    exit 1
  end

  html_link = matched_event['htmlLink']
  if html_link.nil? || html_link.empty?
    puts Rainbow("Error: Event does not have an internet browser link.").red.bright
    exit 1
  end

  puts Rainbow("Opening event '#{matched_event['summary']}' in your browser...").cyan
  
  # Cross-platform open
  host_os = RbConfig::CONFIG['host_os']
  if host_os =~ /mswin|mingw|cygwin/
    system("start \"\" \"#{html_link}\"")
  elsif host_os =~ /darwin/
    system("open \"#{html_link}\"")
  else # linux/bsd
    system("xdg-open \"#{html_link}\" >/dev/null 2>&1")
  end
end

# Command: merge <id1> <id2>
def merge_events_by_friendly_ids(access_token, id1_str, id2_str)
  id1 = id1_str.to_i
  id2 = id2_str.to_i

  if id1 <= 0 || id2 <= 0
    puts Rainbow("Error: Please provide positive integers for event IDs.").red.bright
    exit 1
  end

  if id1 == id2
    puts Rainbow("Error: Cannot merge an event with itself.").red.bright
    exit 1
  end

  # Load all events from cache
  events_by_calendar = get_cached_calendar_events(access_token)
  all_calendars = get_cached_calendar_list(access_token)

  event1 = nil
  event2 = nil
  cal_id1 = nil
  cal_id2 = nil

  events_by_calendar.each do |cal_id, events|
    events.each do |event|
      if event['_friendly_id'] == id1
        event1 = event
        cal_id1 = cal_id
      end
      if event['_friendly_id'] == id2
        event2 = event
        cal_id2 = cal_id
      end
    end
  end

  if event1.nil?
    puts Rainbow("Error: Event with ID #{id1} not found.").red.bright
    exit 1
  end
  if event2.nil?
    puts Rainbow("Error: Event with ID #{id2} not found.").red.bright
    exit 1
  end

  # Check compatibility
  times1 = parse_event_time(event1)
  times2 = parse_event_time(event2)

  unless times1[:start_time] == times2[:start_time] && times1[:end_time] == times2[:end_time] && times1[:all_day] == times2[:all_day]
    puts Rainbow("Error: Events must take place at the exact same time to be merged.").red.bright
    exit 1
  end

  unless event1['_recurrence_freq'] == event2['_recurrence_freq']
    puts Rainbow("Error: Events must have the same repetition frequency pattern (e.g., both Weekly, or both non-recurring) to be merged.").red.bright
    exit 1
  end

  puts Rainbow("Merging Event #{id2} into Event #{id1}...").cyan

  # 1. Merge summaries
  summary1 = event1['summary'] || ""
  summary2 = event2['summary'] || ""
  merged_summary = (summary1 == summary2) ? summary1 : "#{summary1} / #{summary2}"

  # 2. Merge descriptions
  desc1 = event1['description'] || ""
  desc2 = event2['description'] || ""
  merged_desc = [desc1.strip, desc2.strip].reject(&:empty?).join("\n\n---\n\n")

  # 3. Merge attendees
  attendees1 = event1['attendees'] || []
  attendees2 = event2['attendees'] || []
  emails = []
  merged_attendees = []
  (attendees1 + attendees2).each do |att|
    email = att['email']
    if email && !emails.include?(email.downcase)
      emails << email.downcase
      merged_attendees << att
    end
  end

  # 4. Merge location
  loc1 = event1['location'] || ""
  loc2 = event2['location'] || ""
  merged_loc = if loc1.empty?
                 loc2
               elsif loc2.empty?
                 loc1
               elsif loc1 == loc2
                 loc1
               else
                 "#{loc1}, #{loc2}"
               end

  # Perform API update on event1
  update_payload = {
    'summary' => merged_summary,
    'description' => merged_desc,
    'location' => merged_loc
  }
  update_payload['attendees'] = merged_attendees unless merged_attendees.empty?

  # Perform PATCH on event1
  patch_calendar_event(access_token, cal_id1, event1['id'], update_payload)

  # Perform DELETE on event2
  delete_calendar_event(access_token, cal_id2, event2['id'])

  puts Rainbow("Successfully merged event #{id2} into #{id1}!").green
end

# TUI: Generate the Left Pane (Month Grid)
def generate_left_pane(year, month, selected_date)
  lines = []
  lines << "┌──────────────────────┐"
  month_name = Date::MONTHNAMES[month]
  title = "#{month_name} #{year}"
  lines << "│" + title.center(22) + "│"
  lines << "├──────────────────────┤"
  lines << "│ Mo Tu We Th Fr Sa Su │"

  # Find first day of month and last day
  first_day = Date.new(year, month, 1)
  last_day = Date.new(year, month, -1)

  # Pad days at start (Monday = 1, Sunday = 7)
  start_pad = (first_day.wday - 1) % 7

  days = []
  start_pad.times { days << nil }
  (1..last_day.day).each { |d| days << Date.new(year, month, d) }
  while days.size % 7 != 0
    days << nil
  end

  # Group into rows of 7
  days.each_slice(7) do |week|
    parts = []
    week.each do |day|
      if day.nil?
        parts << "  "
      else
        day_str = day.day.to_s.rjust(2)
        if day == selected_date
          parts << Rainbow(day_str).bold.inverse.yellow.to_s
        elsif day == Date.today
          parts << Rainbow(day_str).bold.underline.cyan.to_s
        else
          parts << day_str
        end
      end
    end
    lines << "│ " + parts.join(" ") + " │"
  end

  # Pad with empty rows to keep height consistent (Title(1) + TitleHeader(1) + Divider(1) + WeekdayHeader(1) + 6 rows + Border(1) = 11 lines)
  while lines.size < 11
    lines << "│                      │"
  end
  lines << "└──────────────────────┘"
  lines
end

# TUI: format a single event line inside the TUI schedule pane
def get_tui_event_line_str(time_str, cal_summary, cal_color, summary, priority, show_id, event_id, show_recurrence, recurrence_freq, width = 50)
  target_content_width = width - 3

  time_plain = time_str.ljust(13)
  cal_plain = "[#{cal_summary}]"

  if show_id && event_id
    id_tag = "[#{event_id}] "
  else
    id_tag = ""
  end

  if show_recurrence && recurrence_freq
    rec_tag = "(⟲ #{recurrence_freq[0]}) " # short frequency: D, W, M, Y
  else
    rec_tag = ""
  end

  if priority
    prio_str = (priority % 1 == 0) ? priority.to_i.to_s : sprintf("%.1f", priority)
  else
    prio_str = ""
  end

  if priority
    available_summary_width = target_content_width - 13 - 2 - cal_plain.length - 1 - id_tag.length - rec_tag.length - 1 - prio_str.length
    truncated_summary = summary.length > available_summary_width ? summary[0...[0, available_summary_width - 3].max] + "..." : summary

    padding_length = target_content_width - 13 - 2 - cal_plain.length - 1 - id_tag.length - rec_tag.length - truncated_summary.length - prio_str.length
    padding = " " * [0, padding_length].max

    colored_prio = format_priority_rainbow(prio_str, priority)

    sprintf("  %s  [%s] %s%s%s%s%s",
            Rainbow(sprintf("%-13s", time_str)).green,
            Rainbow(cal_summary).color(cal_color),
            Rainbow(id_tag).color(128, 128, 128),
            Rainbow(rec_tag).color(0, 128, 128).italic,
            Rainbow(truncated_summary).bold,
            padding,
            colored_prio)
  else
    available_summary_width = target_content_width - 13 - 2 - cal_plain.length - 1 - id_tag.length - rec_tag.length
    truncated_summary = summary.length > available_summary_width ? summary[0...[0, available_summary_width - 3].max] + "..." : summary

    sprintf("  %s  [%s] %s%s%s",
            Rainbow(sprintf("%-13s", time_str)).green,
            Rainbow(cal_summary).color(cal_color),
            Rainbow(id_tag).color(128, 128, 128),
            Rainbow(rec_tag).color(0, 128, 128).italic,
            Rainbow(truncated_summary).bold)
  end
end

# TUI: Generate the Right Pane (Event list)
def generate_right_pane_lines(access_token, start_date, show_id, show_recurrence, pane_width, pane_height)
  all_calendars = get_cached_calendar_list(access_token)
  aliases = load_aliases

  selected_calendars = all_calendars.select { |c| c['selected'] }
  if selected_calendars.empty?
    primary = all_calendars.find { |c| c['primary'] } || all_calendars.first
    selected_calendars = [primary].compact
  end

  calendar_map = {}
  selected_calendars.each do |cal|
    calendar_map[cal['id']] = {
      summary: cal['summaryOverride'] || cal['summary']
    }
  end

  color_assignments = get_calendar_colors(selected_calendars)
  cached_events_by_calendar = get_cached_calendar_events(access_token)

  all_events = []
  selected_calendars.each do |cal|
    events = cached_events_by_calendar[cal['id']] || []
    events.each do |event|
      event['_calendar_id'] = cal['id']
      event['_calendar_summary'] = calendar_map[cal['id']][:summary]
      all_events << event
    end
  end

  parsed_events = all_events.map do |event|
    times = parse_event_time(event)
    {
      event: event,
      start_time: times[:start_time],
      end_time: times[:end_time],
      all_day: times[:all_day],
      calendar_id: event['_calendar_id'],
      calendar_summary: event['_calendar_summary'],
      priority: parse_priority(event['description']),
      recurrence_freq: event['_recurrence_freq']
    }
  end

  # Group by day and filter >= start_date
  events_by_day = parsed_events.select { |pe| pe[:start_time].to_date >= start_date }
                               .group_by { |pe| pe[:start_time].to_date }

  lines = []
  current_day = start_date

  # Fetch days sequentially until we fill the pane_height
  while lines.size < pane_height
    day_events = events_by_day[current_day] || []
    
    # Header for the day
    day_name = current_day.strftime("%A, %B %d")
    border_prefix = "┌── #{day_name} "
    padding_dashes = [0, pane_width - border_prefix.length].max
    lines << Rainbow(border_prefix + "─" * padding_dashes).bold.yellow.to_s

    if day_events.empty?
      lines << sprintf("│  %s", Rainbow("No events scheduled").color(128, 128, 128).italic)
    else
      # Sort events: all-day first, then by start_time
      sorted = day_events.sort_by do |pe|
        [pe[:all_day] ? 0 : 1, pe[:start_time], pe[:end_time], pe[:event]['summary'] || ""]
      end

      sorted.each do |pe|
        summary = pe[:event]['summary'] || "(No Title)"
        cal_summary = aliases[pe[:calendar_id]] || pe[:calendar_summary]
        cal_color = color_assignments[pe[:calendar_id]] || :default

        if pe[:all_day]
          time_str = "All Day"
        else
          time_str = "#{pe[:start_time].strftime('%H:%M')} - #{pe[:end_time].strftime('%H:%M')}"
        end

        evt_str = get_tui_event_line_str(time_str, cal_summary, cal_color, summary, pe[:priority], show_id, pe[:event]['_friendly_id'], show_recurrence, pe[:recurrence_freq], pane_width)
        lines << sprintf("│%s", evt_str)

        # Description (first line)
        desc = pe[:event]['description']
        if desc && !desc.strip.empty?
          desc_lines = desc.strip.split("\n").reject { |line| line =~ /^\s*priority:\s*-?\d+(?:\.\d+)?\s*$/i }
          first_line = desc_lines.first
          if first_line && !first_line.strip.empty?
            available_width = pane_width - 8
            truncated_notes = first_line.length > available_width ? first_line[0...[0, available_width - 3].max] + "..." : first_line
            lines << sprintf("│      %s", Rainbow(truncated_notes).color(128, 128, 128).italic)
          end
        end
      end
    end
    lines << "└" + "─" * (pane_width - 1)
    lines << "" # blank separator line
    
    current_day += 1
  end

  # Truncate to pane_height
  lines[0...pane_height]
end

# TUI: Read a key from STDIN safely (arrow keys, q, esc, enter)
def read_key
  char = STDIN.getch
  if char == "\e"
    STDIN.echo = false
    STDIN.raw!
    begin
      if IO.select([STDIN], nil, nil, 0.05)
        next_char = STDIN.getch
        if next_char == "["
          arrow = STDIN.getch
          case arrow
          when "A" then return :up
          when "B" then return :down
          when "C" then return :right
          when "D" then return :left
          end
        end
      else
        return :escape
      end
    rescue
      return :escape
    ensure
      STDIN.cooked!
    end
  elsif char == "q" || char == "\u0003"
    return :quit
  elsif char == "\r" || char == "\n"
    return :enter
  end
  char
end

# Command: interactive (TUI)
def start_tui(access_token, show_id = false, show_recurrence = false)
  selected_date = Date.today
  
  # Hide cursor and clear screen
  print "\e[?25l\e[H\e[2J"

  begin
    loop do
      rows, cols = IO.console.winsize rescue [24, 80]
      
      # Clear screen and move cursor to home
      print "\e[H"

      # Header
      header_str = " my_cal Interactive TUI (Today: #{Date.today.strftime('%b %d, %Y')}) "
      padding_dashes = [0, cols - header_str.length - 2].max
      puts Rainbow("┌" + header_str + "─" * padding_dashes + "┐").bold.cyan

      # We have H - 4 lines for content
      content_height = [5, rows - 4].max
      
      # Generate Left Pane (width is exactly 24 chars)
      left_lines = generate_left_pane(selected_date.year, selected_date.month, selected_date)
      
      # Generate Right Pane (width is cols - 24 - 3 for borders/separators)
      right_pane_width = [20, cols - 27].max
      right_lines = generate_right_pane_lines(access_token, selected_date, show_id, show_recurrence, right_pane_width, content_height)

      # Print side-by-side
      content_height.times do |i|
        left = left_lines[i] || "                        " # 24 spaces
        right = right_lines[i] || ""
        # Pad right to clear end of line
        puts "#{left} │ #{right}\e[K"
      end

      # Footer
      footer_str = " [Arrows] Navigate Selected Day | [q] Quit "
      padding_dashes = [0, cols - footer_str.length - 2].max
      print Rainbow("└" + footer_str + "─" * padding_dashes + "┘").bold.cyan + "\e[K"
      
      # Wait for key
      key = read_key
      case key
      when :quit
        break
      when :left
        selected_date -= 1
      when :right
        selected_date += 1
      when :up
        selected_date -= 7
      when :down
        selected_date += 7
      end
    end
  ensure
    # Restore cursor and clear screen on exit
    print "\e[?25h\e[H\e[2J"
  end
end

if __FILE__ == $0
  # Check if the last argument is '?' to show detailed help
  if ARGV.last == "?"
    ARGV.pop
    command = ARGV[0]
    if command.nil? || command.empty?
      print_general_usage
      exit 0
    else
      show_detailed_help(command)
      exit 0
    end
  end

  # Check for -i flag anywhere in command line
  show_id = ARGV.delete("-i") ? true : false
  # Check for -r flag anywhere in command line
  show_recurrence = ARGV.delete("-r") ? true : false

  command = ARGV[0]
  oauth_path = ENV['GCAL_OAUTH_PATH'] || DEFAULT_OAUTH_PATH

  # If no command is provided, launch interactive TUI by default!
  if command.nil? || command == 'interactive'
    begin
      access_token = get_access_token(oauth_path)
      start_tui(access_token, show_id, show_recurrence)
      exit 0
    rescue => e
      STDERR.puts Rainbow("Error: #{e.message}").red.bright
      exit 1
    end
  end
  
  if command == 'test'
    require_relative 'test_my_cal'
    exit 0
  end

  unless ['list', 'week', 'alias', 'month', 'add_priority', 'del_event', 'search', 'search_week', 'search_month', 'search_year', 'reload', 'today', 'next', 'web', 'merge', 'year', 'default', 'add', 'add-full'].include?(command)
    print_general_usage
    exit 1
  end

  begin
    access_token = get_access_token(oauth_path)
    if command == 'list'
      list_calendars(access_token)
    elsif command == 'today'
      show_today_schedule(access_token, show_id, show_recurrence)
    elsif command == 'next'
      show_next_event(access_token, show_id)
    elsif command == 'week'
      calendar_name = ARGV[1]
      show_week_schedule(access_token, calendar_name, show_id, show_recurrence)
    elsif command == 'month'
      calendar_name = ARGV[1]
      show_month_schedule(access_token, calendar_name, show_id, show_recurrence)
    elsif command == 'year'
      calendar_name = ARGV[1]
      show_year_schedule(access_token, calendar_name, show_id, show_recurrence)
    elsif command == 'web'
      event_id = ARGV[1]
      if event_id.nil?
        puts Rainbow("Error: Please specify the event friendly ID.").red.bright
        exit 1
      end
      open_event_in_browser(access_token, event_id)
    elsif command == 'merge'
      id1 = ARGV[1]
      id2 = ARGV[2]
      if id1.nil? || id2.nil?
        puts Rainbow("Error: Please specify both event friendly IDs to merge. Usage: ./my_cal merge <id1> <id2>").red.bright
        exit 1
      end
      merge_events_by_friendly_ids(access_token, id1, id2)
    elsif command == 'add_priority'
      calendar_name = ARGV[1]
      if calendar_name.nil?
        puts Rainbow("Error: Please specify the calendar name or ID.").red.bright
        exit 1
      end
      add_priority_to_future_events(access_token, calendar_name)
    elsif command == 'del_event'
      event_id = ARGV[1]
      if event_id.nil?
        puts Rainbow("Error: Please specify the event ID to delete.").red.bright
        exit 1
      end
      delete_event_by_friendly_id(access_token, event_id)
    elsif command == 'default'
      calendar_name = ARGV[1]
      if calendar_name.nil?
        puts Rainbow("Error: Please specify the calendar name or ID.").red.bright
        exit 1
      end
      set_default_calendar(access_token, calendar_name)
    elsif command == 'add'
      text = ARGV[1]
      if text.nil? || text.strip.empty?
        puts Rainbow("Error: Please specify the quick-add text. Example: ./my_cal add \"Meeting tomorrow at 3pm\"").red.bright
        exit 1
      end
      quick_add_event(access_token, text)
    elsif command == 'add-full'
      calendar_name = ARGV[1]
      summary = ARGV[2]
      start_time = ARGV[3]
      end_time = ARGV[4]
      desc = ARGV[5]
      loc = ARGV[6]
      if calendar_name.nil? || summary.nil? || start_time.nil? || end_time.nil?
        puts Rainbow("Error: Please specify calendar, summary, start time, and end time. Usage: ./my_cal add-full <cal-name> <summary> <start-time> <end-time> [description] [location]").red.bright
        exit 1
      end
      add_full_event(access_token, calendar_name, summary, start_time, end_time, desc, loc)
    elsif command == 'alias'
      calendar_name = ARGV[1]
      shortcut = ARGV[2]

      if calendar_name.nil?
        puts Rainbow("Error: Please specify the calendar name or ID.").red.bright
        exit 1
      end

      set_calendar_alias(access_token, calendar_name, shortcut)
    elsif ['search', 'search_week', 'search_month', 'search_year'].include?(command)
      word = ARGV[1]
      if word.nil? || word.strip.empty?
        puts Rainbow("Error: Please specify the search term.").red.bright
        exit 1
      end
      
      scope = case command
              when 'search' then :all_sequential
              when 'search_week' then :week
              when 'search_month' then :month
              when 'search_year' then :year
              end
      
      perform_calendar_search(access_token, word, scope, show_id, show_recurrence)
    elsif command == 'reload'
      reload_calendar_cache(access_token)
    end
  rescue => e
    STDERR.puts Rainbow("Error: #{e.message}").red.bright
    exit 1
  end
end
