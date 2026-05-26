require 'minitest/autorun'
require_relative 'my_cal'

class TestMyCal < Minitest::Test
  def test_parse_event_time_timed
    event = {
      'start' => { 'dateTime' => '2026-05-27T10:00:00+02:00' },
      'end' => { 'dateTime' => '2026-05-27T11:00:00+02:00' }
    }
    parsed = parse_event_time(event)
    refute parsed[:all_day]
    assert_equal 10, parsed[:start_time].hour
    assert_equal 11, parsed[:end_time].hour
    assert_equal 27, parsed[:start_time].day
  end

  def test_parse_event_time_all_day
    event = {
      'start' => { 'date' => '2026-05-25' },
      'end' => { 'date' => '2026-05-26' }
    }
    parsed = parse_event_time(event)
    assert parsed[:all_day]
    assert_equal 0, parsed[:start_time].hour
    assert_equal 25, parsed[:start_time].day
    assert_equal 26, parsed[:end_time].day
  end

  def test_parse_event_time_fallback
    event = {}
    parsed = parse_event_time(event)
    refute parsed[:all_day]
    assert_kind_of Time, parsed[:start_time]
    assert_kind_of Time, parsed[:end_time]
  end

  def test_get_calendar_colors
    calendars = [
      { 'id' => 'cal1' },
      { 'id' => 'cal2' },
      { 'id' => 'cal3' }
    ]
    colors = get_calendar_colors(calendars)
    assert_equal 3, colors.size
    assert_includes [:cyan, :green, :yellow, :magenta, :blue, :orange], colors['cal1']
    assert_includes [:cyan, :green, :yellow, :magenta, :blue, :orange], colors['cal2']
    assert_includes [:cyan, :green, :yellow, :magenta, :blue, :orange], colors['cal3']
    refute_equal colors['cal1'], colors['cal2']
  end

  def test_get_oauth_credentials_missing_file
    assert_raises(RuntimeError) do
      get_oauth_credentials("/nonexistent/file")
    end
  end

  def test_get_oauth_credentials_parsing
    mock_json = '{"token": "t1", "refresh_token": "rt1", "token_uri": "tu1", "client_id": "c1", "client_secret": "cs1"}'

    File.stub :exist?, true do
      mock_capture3 = lambda do |cmd, opts|
        assert_equal "python3", cmd
        status = Minitest::Mock.new
        status.expect :success?, true
        [mock_json, "", status]
      end

      Open3.stub :capture3, mock_capture3 do
        creds = get_oauth_credentials("/dummy/path")
        assert_equal "t1", creds["token"]
        assert_equal "rt1", creds["refresh_token"]
        assert_equal "c1", creds["client_id"]
      end
    end
  end

  def test_get_access_token_from_valid_cache
    cached_data = {
      "client_id" => "c1",
      "client_secret" => "cs1",
      "refresh_token" => "rt1",
      "token_uri" => "tu1",
      "access_token" => "cached_t1",
      "expires_at" => Time.now.to_i + 1000
    }

    File.stub :exist?, lambda { |path| path == CREDENTIALS_FILE ? true : false } do
      File.stub :read, lambda { |path| path == CREDENTIALS_FILE ? JSON.generate(cached_data) : "" } do
        token = get_access_token("/dummy/path")
        assert_equal "cached_t1", token
      end
    end
  end

  def test_load_and_save_aliases
    aliases = { "id1" => "alias1" }

    mock_write = lambda do |path, content|
      assert_equal ALIASES_FILE, path
      assert_equal JSON.generate(aliases), content
      content.size
    end

    File.stub :exist?, true do
      File.stub :read, JSON.generate(aliases) do
        assert_equal aliases, load_aliases
      end
    end

    File.stub :write, mock_write do
      save_aliases(aliases)
    end
  end

  def test_parse_priority
    assert_equal 5.0, parse_priority("priority: 5.0")
    assert_equal 9.0, parse_priority("priority: 9")
    assert_equal 9.5, parse_priority("notes\npriority: 9.5\nmore notes")
    assert_equal 10.0, parse_priority("priority: 12.5") # clamped max
    assert_equal 0.0, parse_priority("priority: -2.0") # clamped min
    assert_nil parse_priority("no priority here")
    assert_nil parse_priority("")
  end

  def test_render_event_line_with_priority_and_id
    out, err = capture_io do
      render_event_line("10:00 - 11:00", "main", :cyan, "Discussion", 5.0, true, "lgn6s40u_extra")
    end
    assert_match /lgn6s40u/, out
    assert_match /Discussion/, out
    assert_match /5/, out
  end

  def test_render_event_line_without_priority_and_without_id
    out, err = capture_io do
      render_event_line("10:00 - 11:00", "main", :cyan, "Discussion", nil, false, nil)
    end
    assert_match /Discussion/, out
    refute_match /priority/, out
  end

  def test_delete_event_by_friendly_id_success
    access_token = "dummy_token"
    friendly_id = "1"
    
    mock_calendars = [
      { 'id' => 'cal_id_1', 'selected' => true, 'summary' => 'Calendar 1' }
    ]
    
    mock_events = {
      'cal_id_1' => [
        { 'id' => 'lgn6s40u_extra', '_friendly_id' => 1, 'summary' => 'Discussion' }
      ]
    }
    
    delete_called = false
    
    self.stub :get_cached_calendar_list, mock_calendars do
      self.stub :get_cached_calendar_events, mock_events do
        self.stub :delete_calendar_event, lambda { |token, cal_id, ev_id|
          assert_equal "cal_id_1", cal_id
          assert_equal "lgn6s40u_extra", ev_id
          delete_called = true
        } do
          out, err = capture_io do
            delete_event_by_friendly_id(access_token, friendly_id)
          end
          assert delete_called
          assert_match /Deleted event 'Discussion'/, out
        end
      end
    end
  end

  def test_delete_event_by_friendly_id_not_found
    access_token = "dummy_token"
    friendly_id = "999"
    
    mock_calendars = [
      { 'id' => 'cal_id_1', 'selected' => true, 'summary' => 'Calendar 1' }
    ]
    
    self.stub :get_cached_calendar_list, mock_calendars do
      self.stub :get_cached_calendar_events, {} do
        out, err = capture_io do
          assert_raises(SystemExit) do
            delete_event_by_friendly_id(access_token, friendly_id)
          end
        end
        assert_match /not found/, out
      end
    end
  end

  def test_get_credentials_first_run
    mock_gcalcli_creds = {
      "token" => "t1",
      "refresh_token" => "rt1",
      "token_uri" => "tu1",
      "client_id" => "c1",
      "client_secret" => "cs1"
    }

    File.stub :exist?, lambda { |path| path == CREDENTIALS_FILE ? false : true } do
      self.stub :get_oauth_credentials, mock_gcalcli_creds do
        write_called = false
        File.stub :write, lambda { |path, content|
          if path == CREDENTIALS_FILE
            write_called = true
            data = JSON.parse(content)
            assert_equal "t1", data["token"]
            assert_equal "rt1", data["refresh_token"]
          end
          content.size
        } do
          out, err = capture_io do
            creds = get_credentials("/dummy/path")
            assert_equal "t1", creds["token"]
            assert_equal "rt1", creds["refresh_token"]
          end
          assert write_called
          assert_match /Initializing credentials from gcalcli/, out
        end
      end
    end
  end

  def test_event_matches
    event = {
      'summary' => 'Research Meeting with Sam',
      'description' => 'priority: 5.0'
    }
    assert event_matches?(event, "research")
    assert event_matches?(event, "SAM")
    assert event_matches?(event, "priority")
    refute event_matches?(event, "nonexistent")
  end

  def test_perform_calendar_search_sequential_hit
    access_token = "dummy_token"
    mock_calendars = [
      { 'id' => 'cal_1', 'summary' => 'Personal' }
    ]
    mock_cached_events = {
      'cal_1' => [
        { 'id' => 'ev_1', 'summary' => 'Meeting with Sam', 'start' => { 'dateTime' => Time.now.iso8601 }, 'end' => { 'dateTime' => (Time.now + 3600).iso8601 } }
      ]
    }

    self.stub :fetch_calendar_list, mock_calendars do
      self.stub :get_cached_calendar_events, mock_cached_events do
        out, err = capture_io do
          perform_calendar_search(access_token, "sam", :all_sequential, false)
        end
        assert_match /Matching Event Found:/, out
        assert_match /Meeting with Sam/, out
      end
    end
  end

  def test_perform_calendar_search_explicit_scope
    access_token = "dummy_token"
    mock_calendars = [
      { 'id' => 'cal_1', 'summary' => 'Personal' }
    ]
    mock_cached_events = {
      'cal_1' => [
        { 'id' => 'ev_1', 'summary' => 'Discussion Meeting', 'start' => { 'dateTime' => Time.now.iso8601 }, 'end' => { 'dateTime' => (Time.now + 3600).iso8601 } }
      ]
    }

    self.stub :fetch_calendar_list, mock_calendars do
      self.stub :get_cached_calendar_events, mock_cached_events do
        out, err = capture_io do
          perform_calendar_search(access_token, "discussion", :week, false)
        end
        assert_match /Searching all calendars for 'discussion' in this week.../, out
        assert_match /Discussion Meeting/, out
      end
    end
  end

  def test_get_cached_calendar_events_caching_and_expiration
    access_token = "dummy_token"
    mock_calendars = [{ 'id' => 'cal1' }]
    mock_update_times = { 'cal1' => '2026-05-25T22:52:12.000Z' }
    
    # 1. Test cache exists and is fresh
    fresh_cache_data = {
      'last_download_at' => Time.now.to_i - 1000,
      'calendar_updates' => { 'cal1' => '2026-05-25T22:52:12.000Z' },
      'events_by_calendar' => { 'cal1' => [] }
    }
    
    self.stub :fetch_calendar_list, mock_calendars do
      self.stub :fetch_all_calendar_update_times, mock_update_times do
        File.stub :exist?, lambda { |path| path == CACHE_FILE ? true : false } do
          File.stub :read, lambda { |path| path == CACHE_FILE ? JSON.generate(fresh_cache_data) : "" } do
            File.stub :write, lambda { |path, content| assert_equal CACHE_FILE, path; content.size } do
              cached = get_cached_calendar_events(access_token)
              assert_equal [], cached['cal1']
            end
          end
        end
      end
    end
    
    # 2. Test cache is stale (different update times)
    stale_cache_data = {
      'last_download_at' => Time.now.to_i - 1000,
      'calendar_updates' => { 'cal1' => '2026-05-25T22:00:00.000Z' }, # stale!
      'events_by_calendar' => { 'cal1' => [] }
    }
    
    reload_called = false
    mock_reload = lambda { |token|
      reload_called = true
    }
    
    self.stub :fetch_calendar_list, mock_calendars do
      self.stub :fetch_all_calendar_update_times, mock_update_times do
        self.stub :reload_calendar_cache, mock_reload do
          File.stub :exist?, lambda { |path| path == CACHE_FILE ? true : false } do
            reads = 0
            File.stub :read, lambda { |path|
              reads += 1
              if reads == 1
                JSON.generate(stale_cache_data)
              else
                JSON.generate(fresh_cache_data)
              end
            } do
              cached = get_cached_calendar_events(access_token)
              assert reload_called
              assert_equal [], cached['cal1']
            end
          end
        end
      end
    end
  end

  def test_show_today_schedule
    access_token = "dummy_token"
    mock_calendars = [
      { 'id' => 'cal_1', 'summary' => 'Personal', 'selected' => true }
    ]
    mock_cached_events = {
      'cal_1' => [
        { 'id' => 'ev_1', 'summary' => 'Meeting with Ben', 'start' => { 'dateTime' => Time.now.iso8601 }, 'end' => { 'dateTime' => (Time.now + 3600).iso8601 } }
      ]
    }

    self.stub :get_cached_calendar_list, mock_calendars do
      self.stub :get_cached_calendar_events, mock_cached_events do
        out, err = capture_io do
          show_today_schedule(access_token, false)
        end
        assert_match /Schedule for Today and Tomorrow:/, out
        assert_match /Meeting with Ben/, out
      end
    end
  end

  def test_show_next_event
    access_token = "dummy_token"
    mock_calendars = [
      { 'id' => 'cal_1', 'summary' => 'Personal', 'selected' => true }
    ]
    mock_cached_events = {
      'cal_1' => [
        { 'id' => 'ev_active', '_friendly_id' => 1, 'summary' => 'Active Event', 'start' => { 'dateTime' => (Time.now - 1800).iso8601 }, 'end' => { 'dateTime' => (Time.now + 1800).iso8601 } },
        { 'id' => 'ev_future', '_friendly_id' => 2, 'summary' => 'Future Event', 'start' => { 'dateTime' => (Time.now + 7200).iso8601 }, 'end' => { 'dateTime' => (Time.now + 10800).iso8601 } }
      ]
    }

    self.stub :get_cached_calendar_list, mock_calendars do
      self.stub :get_cached_calendar_events, mock_cached_events do
        out, err = capture_io do
          show_next_event(access_token, true)
        end
        assert_match /Happening Now/, out
        assert_match /Active Event/, out
        assert_match /ID: 1/, out
      end
    end
  end

  def test_open_event_in_browser_success
    access_token = "dummy_token"
    mock_events = {
      'cal_1' => [
        { 'id' => 'ev_1', '_friendly_id' => 1, 'summary' => 'Open Me', 'htmlLink' => 'http://example.com/event1' }
      ]
    }
    system_called = false
    self.stub :get_cached_calendar_events, mock_events do
      self.stub :system, lambda { |cmd|
        assert_match /example\.com/, cmd
        system_called = true
        true
      } do
        out, err = capture_io do
          open_event_in_browser(access_token, "1")
        end
        assert system_called
        assert_match /Opening event 'Open Me' in your browser/, out
      end
    end
  end

  def test_open_event_in_browser_not_found
    access_token = "dummy_token"
    mock_events = { 'cal_1' => [] }
    self.stub :get_cached_calendar_events, mock_events do
      out, err = capture_io do
        assert_raises(SystemExit) do
          open_event_in_browser(access_token, "999")
        end
      end
      assert_match /Event with ID 999 not found/, out
    end
  end

  def test_merge_events_success
    access_token = "dummy_token"
    mock_calendars = [
      { 'id' => 'cal_1', 'summary' => 'Personal', 'selected' => true }
    ]
    mock_events = {
      'cal_1' => [
        {
          'id' => 'ev_1',
          '_friendly_id' => 1,
          'summary' => 'Task A',
          'description' => 'notes A',
          'location' => 'Room 1',
          'start' => { 'dateTime' => '2026-05-27T10:00:00+02:00' },
          'end' => { 'dateTime' => '2026-05-27T11:00:00+02:00' },
          '_recurrence_freq' => 'Weekly',
          'attendees' => [{ 'email' => 'a@example.com' }]
        },
        {
          'id' => 'ev_2',
          '_friendly_id' => 2,
          'summary' => 'Task B',
          'description' => 'notes B',
          'location' => 'Room 2',
          'start' => { 'dateTime' => '2026-05-27T10:00:00+02:00' },
          'end' => { 'dateTime' => '2026-05-27T11:00:00+02:00' },
          '_recurrence_freq' => 'Weekly',
          'attendees' => [{ 'email' => 'b@example.com' }, { 'email' => 'a@example.com' }]
        }
      ]
    }

    patch_called = false
    delete_called = false

    self.stub :get_cached_calendar_list, mock_calendars do
      self.stub :get_cached_calendar_events, mock_events do
        self.stub :patch_calendar_event, lambda { |token, cal_id, ev_id, payload|
          assert_equal "cal_1", cal_id
          assert_equal "ev_1", ev_id
          assert_equal "Task A / Task B", payload['summary']
          assert_equal "notes A\n\n---\n\nnotes B", payload['description']
          assert_equal "Room 1, Room 2", payload['location']
          assert_equal 2, payload['attendees'].size
          patch_called = true
        } do
          self.stub :delete_calendar_event, lambda { |token, cal_id, ev_id|
            assert_equal "cal_1", cal_id
            assert_equal "ev_2", ev_id
            delete_called = true
          } do
            out, err = capture_io do
              merge_events_by_friendly_ids(access_token, "1", "2")
            end
            assert patch_called
            assert delete_called
            assert_match /Successfully merged event 2 into 1/, out
          end
        end
      end
    end
  end

  def test_merge_events_incompatible_times
    access_token = "dummy_token"
    mock_events = {
      'cal_1' => [
        {
          'id' => 'ev_1',
          '_friendly_id' => 1,
          'start' => { 'dateTime' => '2026-05-27T10:00:00+02:00' },
          'end' => { 'dateTime' => '2026-05-27T11:00:00+02:00' }
        },
        {
          'id' => 'ev_2',
          '_friendly_id' => 2,
          'start' => { 'dateTime' => '2026-05-27T11:00:00+02:00' },
          'end' => { 'dateTime' => '2026-05-27T12:00:00+02:00' }
        }
      ]
    }

    self.stub :get_cached_calendar_list, [] do
      self.stub :get_cached_calendar_events, mock_events do
        out, err = capture_io do
          assert_raises(SystemExit) do
            merge_events_by_friendly_ids(access_token, "1", "2")
          end
        end
        assert_match /Events must take place at the exact same time/, out
      end
    end
  end

  def test_merge_events_incompatible_recurrence
    access_token = "dummy_token"
    mock_events = {
      'cal_1' => [
        {
          'id' => 'ev_1',
          '_friendly_id' => 1,
          'start' => { 'dateTime' => '2026-05-27T10:00:00+02:00' },
          'end' => { 'dateTime' => '2026-05-27T11:00:00+02:00' },
          '_recurrence_freq' => 'Weekly'
        },
        {
          'id' => 'ev_2',
          '_friendly_id' => 2,
          'start' => { 'dateTime' => '2026-05-27T10:00:00+02:00' },
          'end' => { 'dateTime' => '2026-05-27T11:00:00+02:00' },
          '_recurrence_freq' => 'Daily'
        }
      ]
    }

    self.stub :get_cached_calendar_list, [] do
      self.stub :get_cached_calendar_events, mock_events do
        out, err = capture_io do
          assert_raises(SystemExit) do
            merge_events_by_friendly_ids(access_token, "1", "2")
          end
        end
        assert_match /Events must have the same repetition frequency pattern/, out
      end
    end
  end

  def test_generate_left_pane
    lines = generate_left_pane(2026, 5, Date.new(2026, 5, 26))
    assert_equal 12, lines.size
    assert_match /May 2026/, lines[1]
    assert_match /Mo Tu We Th Fr Sa Su/, lines[3]
  end

  def test_show_year_schedule_success
    access_token = "dummy_token"
    mock_calendars = [
      { 'id' => 'cal_1', 'summary' => 'Personal', 'selected' => true }
    ]
    year = Time.now.year
    mock_cached_events = {
      'cal_1' => [
        {
          'id' => 'ev_1',
          '_friendly_id' => 1,
          'summary' => 'Yearly Goal Party',
          'start' => { 'dateTime' => "#{year}-06-15T12:00:00+02:00" },
          'end' => { 'dateTime' => "#{year}-06-15T14:00:00+02:00" },
          '_recurrence_freq' => nil
        }
      ]
    }

    self.stub :get_cached_calendar_list, mock_calendars do
      self.stub :get_cached_calendar_events, mock_cached_events do
        out, err = capture_io do
          show_year_schedule(access_token, "Personal", true, false)
        end
        assert_match /Yearly Schedule for #{year}/, out
        assert_match /Yearly Goal Party/, out
        assert_match /\[1\]/, out
      end
    end
  end

  def test_show_week_schedule_with_calendar
    access_token = "dummy_token"
    mock_calendars = [
      { 'id' => 'cal_1', 'summary' => 'Personal', 'selected' => true }
    ]
    monday = Date.today - ((Date.today.wday - 1) % 7)
    mock_cached_events = {
      'cal_1' => [
        {
          'id' => 'ev_1',
          '_friendly_id' => 1,
          'summary' => 'Weekly Lunch',
          'start' => { 'dateTime' => "#{monday.to_s}T12:00:00+02:00" },
          'end' => { 'dateTime' => "#{monday.to_s}T13:00:00+02:00" },
          '_recurrence_freq' => nil
        }
      ]
    }

    self.stub :get_cached_calendar_list, mock_calendars do
      self.stub :get_cached_calendar_events, mock_cached_events do
        out, err = capture_io do
          show_week_schedule(access_token, "Personal", true, false)
        end
        assert_match /Weekly Schedule/, out
        assert_match /Weekly Lunch/, out
      end
    end
  end

  def test_show_week_schedule_without_calendar
    access_token = "dummy_token"
    mock_calendars = [
      { 'id' => 'cal_1', 'summary' => 'Personal', 'selected' => true }
    ]
    monday = Date.today - ((Date.today.wday - 1) % 7)
    mock_cached_events = {
      'cal_1' => [
        {
          'id' => 'ev_1',
          '_friendly_id' => 1,
          'summary' => 'Weekly Lunch',
          'start' => { 'dateTime' => "#{monday.to_s}T12:00:00+02:00" },
          'end' => { 'dateTime' => "#{monday.to_s}T13:00:00+02:00" },
          '_recurrence_freq' => nil
        }
      ]
    }

    self.stub :get_cached_calendar_list, mock_calendars do
      self.stub :get_cached_calendar_events, mock_cached_events do
        out, err = capture_io do
          show_week_schedule(access_token, nil, true, false)
        end
        assert_match /Weekly Schedule/, out
        assert_match /Weekly Lunch/, out
      end
    end
  end

  def test_show_month_schedule_with_calendar
    access_token = "dummy_token"
    mock_calendars = [
      { 'id' => 'cal_1', 'summary' => 'Personal', 'selected' => true }
    ]
    next_month = Date.today.next_month
    target_date = Date.new(next_month.year, next_month.month, 15)
    mock_cached_events = {
      'cal_1' => [
        {
          'id' => 'ev_1',
          '_friendly_id' => 1,
          'summary' => 'Monthly Sync',
          'start' => { 'dateTime' => "#{target_date.to_s}T10:00:00+02:00" },
          'end' => { 'dateTime' => "#{target_date.to_s}T11:00:00+02:00" },
          '_recurrence_freq' => nil
        }
      ]
    }

    self.stub :get_cached_calendar_list, mock_calendars do
      self.stub :get_cached_calendar_events, mock_cached_events do
        out, err = capture_io do
          show_month_schedule(access_token, "Personal", true, false)
        end
        assert_match /Schedule for 'Personal'/, out
        assert_match /Monthly Sync/, out
      end
    end
  end

  def test_show_month_schedule_without_calendar
    access_token = "dummy_token"
    mock_calendars = [
      { 'id' => 'cal_1', 'summary' => 'Personal', 'selected' => true }
    ]
    next_month = Date.today.next_month
    target_date = Date.new(next_month.year, next_month.month, 15)
    mock_cached_events = {
      'cal_1' => [
        {
          'id' => 'ev_1',
          '_friendly_id' => 1,
          'summary' => 'Monthly Sync',
          'start' => { 'dateTime' => "#{target_date.to_s}T10:00:00+02:00" },
          'end' => { 'dateTime' => "#{target_date.to_s}T11:00:00+02:00" },
          '_recurrence_freq' => nil
        }
      ]
    }

    self.stub :get_cached_calendar_list, mock_calendars do
      self.stub :get_cached_calendar_events, mock_cached_events do
        out, err = capture_io do
          show_month_schedule(access_token, nil, true, false)
        end
        assert_match /Schedule for Next Month/, out
        assert_match /Monthly Sync/, out
      end
    end
  end

  def test_set_default_calendar_success
    access_token = "dummy_token"
    mock_cal = { 'id' => 'cal_default', 'summary' => 'Personal' }
    
    self.stub :resolve_calendar, mock_cal do
      File.stub :exist?, true do
        File.stub :read, "{}" do
          File.stub :write, lambda { |path, content|
            assert_equal File.join(CONFIG_DIR, "config.json"), path
            config = JSON.parse(content)
            assert_equal 'cal_default', config['default_calendar_id']
            content.size
          } do
            out, err = capture_io do
              set_default_calendar(access_token, "Personal")
            end
            assert_match /Default calendar set to 'Personal'/, out
          end
        end
      end
    end
  end

  def test_quick_add_event_success
    access_token = "dummy_token"
    mock_config = { 'default_calendar_id' => 'cal_default' }
    
    self.stub :load_config, mock_config do
      mock_response = Minitest::Mock.new
      mock_response.expect :is_a?, true, [Class]
      mock_response.expect :body, JSON.generate({
        'summary' => 'Quick Meeting',
        'start' => { 'dateTime' => '2026-05-27T10:00:00+02:00' }
      })

      http_mock = Object.new
      class << http_mock
        attr_accessor :response
        def use_ssl=(val); end
        def request(req)
          raise "Invalid authorization header" unless req['Authorization'] == "Bearer dummy_token"
          raise "Invalid path" unless req.path.include?("quickAdd")
          @response
        end
      end
      http_mock.response = mock_response

      Net::HTTP.stub :new, lambda { |host, port| http_mock } do
        self.stub :update_local_cache_for_calendar, true do
          out, err = capture_io do
            quick_add_event(access_token, "Dentist appointment tomorrow")
          end
          assert_match /Quick-added event 'Quick Meeting'/, out
        end
      end
    end
  end

  def test_add_full_event_success
    access_token = "dummy_token"
    mock_cal = { 'id' => 'cal_1', 'summary' => 'Personal' }
    
    self.stub :resolve_calendar, mock_cal do
      mock_response = Minitest::Mock.new
      mock_response.expect :is_a?, true, [Class]
      mock_response.expect :body, "{}"

      http_mock = Object.new
      class << http_mock
        attr_accessor :response
        def use_ssl=(val); end
        def request(req)
          raise "Invalid authorization header" unless req['Authorization'] == "Bearer dummy_token"
          raise "Invalid path" unless req.path.include?("events")
          payload = JSON.parse(req.body)
          raise "Invalid summary" unless payload['summary'] == "Lunch with Ben"
          @response
        end
      end
      http_mock.response = mock_response

      Net::HTTP.stub :new, lambda { |host, port| http_mock } do
        self.stub :update_local_cache_for_calendar, true do
          out, err = capture_io do
            add_full_event(access_token, "Personal", "Lunch with Ben", "2026-05-27 12:00", "2026-05-27 13:00", "Discuss project", "Cafe")
          end
          assert_match /Successfully added event 'Lunch with Ben' to calendar 'Personal'/, out
        end
      end
    end
  end

  def test_show_detailed_help
    out_add, _ = capture_io { show_detailed_help("add") }
    assert_match /Command: add/, out_add
    assert_match /Quick-adds an event to your default calendar/, out_add

    out_add_full, _ = capture_io { show_detailed_help("add-full") }
    assert_match /Command: add-full/, out_add_full
    assert_match /Creates a fully configured event/, out_add_full

    out_default, _ = capture_io { show_detailed_help("default") }
    assert_match /Command: default/, out_default
    assert_match /Sets the persistent default calendar/, out_default
  end

  def test_print_general_usage
    out, _ = capture_io { print_general_usage }
    assert_match /Usage:/, out
    assert_match /Show interactive side-by-side month\/schedule TUI/, out
    assert_match /Show all calendars and status/, out
    assert_match /Quick-add an event to the default calendar using natural language/, out
  end

  def test_check_dependencies_satisfied
    # Stub Gem::Specification and system calls to mock fully satisfied dependencies
    Gem::Specification.stub :find_by_name, true do
      self.stub :system, true do
        out, _ = capture_io { check_dependencies }
        assert_match /Checking Program Dependencies/, out
        assert_match /Rainbow Ruby Gem: Installed/, out
        assert_match /System Command 'python3': Installed/, out
        assert_match /All dependencies \(both core and optional development tools\) are satisfied!/, out
      end
    end
  end

  def test_check_dependencies_missing
    # Stub Gem::Specification to raise MissingSpecError and system to return false to mock missing dependencies
    error_mock = lambda { |name| raise Gem::MissingSpecError.new(Gem::Specification.new, "rainbow") }
    Gem::Specification.stub :find_by_name, error_mock do
      self.stub :system, false do
        out, _ = capture_io { check_dependencies }
        assert_match /Checking Program Dependencies/, out
        assert_match /Rainbow Ruby Gem:.*Missing/, out
        assert_match /System Command 'python3':.*Missing/, out
        assert_match /To fix: Run 'sudo apt install python3'/, out
        assert_match /To fix: Run 'sudo gem install rainbow'/, out
        assert_match /Some core dependencies are missing!/, out
      end
    end
  end
end
