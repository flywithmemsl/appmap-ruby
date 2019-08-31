# frozen_string_literal: true

module AppMap
  module Middleware
    # RecordButton embeds a graphical AppMap recording tool into the HTML response.
    class RecordButton
      SCRIPT_SRC = 'script-src'
      UNSAFE_INLINE = "'unsafe-inline'"

      def initialize(app)
        require 'appmap/command/record'
        require 'appmap/command/upload'
        require 'appmap/trace/tracer'
        require 'appmap/config'
        require 'nokogiri'
        require 'pathname'
        require 'json'

        @app = app
        @features = AppMap.inspect(config)
        @functions = @features.map(&:collect_functions).flatten
      end

      def output_scenario(scenario_data)
        if appland_url
          AppMap::Command::Upload.new(config, JSON.parse(scenario_data), appland_url, 1).perform
        else
          File.open("appmap-recording-#{Time.now.to_i}.json", 'w') do |file|
            file.puts(scenario_data)
          end
          nil
        end
      end

      def event_loop
        loop do
          event = @tracer.next_event if @tracer
          if event
            @events << event.to_h
          else
            sleep 0.0001
          end
        end
      end

      def start_recording
        return [ false, 'Recording is already in progress' ] if @tracer

        @events = []
        @tracer = AppMap::Trace.tracers.trace(@functions)
        @event_thread = Thread.new { event_loop }
        @event_thread.abort_on_exception = true

        [ true ]
      end

      def stop_recording
        return [ false, 'No recording is in progress' ] unless @tracer

        tracer = @tracer
        @tracer = nil

        AppMap::Trace.tracers.delete(tracer)

        @event_thread.exit
        @event_thread.join
        @event_thread = nil

        # Delete the events which are calls to or returns from the URL path _appmap/record
        # because these are not of interest to the user.
        is_control_command_event = lambda do |event|
          event[:event] == :call &&
            event[:http_server_request] &&
            event[:http_server_request][:path_info] == '/_appmap/record'
        end
        control_command_events = @events.select(&is_control_command_event)

        is_return_from_control_command_event = lambda do |event|
          event[:parent_id] && control_command_events.find { |e| e[:id] == event[:parent_id] }
        end

        @events.delete_if(&is_control_command_event)
        @events.delete_if(&is_return_from_control_command_event)

        require 'appmap/command/record'
        metadata = AppMap::Command::Record.detect_metadata
        uuid = output_scenario(JSON.generate(classMap: @features, metadata: metadata, events: @events))

        [ true, uuid ]
      end

      def call(env)
        req = Rack::Request.new(env)
        if req.path == '/_appmap/record'
          handle_record_request(env['REQUEST_METHOD'])
        else
          handle_response(*@app.call(env))
        end
      end

      def handle_response(status, headers, response)
        return [status, headers, response] unless html_response?(headers)

        new_response = []
        response.each do |body|
          body = do_html_injection(body)
          new_response.push(body)
        end

        content_length = new_response.reduce(0) do |total, body|
          total + body.bytesize
        end

        headers['Content-Length'] = content_length.to_s

        write_content_security_policy(headers)

        [status, headers, new_response]
      end

      def recording_state
        [ 200, { enabled: recording? }.to_json ]
      end

      def handle_record_request(method)
        status, body = \
          if method.eql?('GET')
            recording_state
          elsif method.eql?('POST')
            start_recording
          elsif method.eql?('DELETE')
            stop_recording
          else
            [ 404, '' ]
          end

        status = 200 if status == true
        status = 500 if status == false

        [status, { 'Content-Type' => 'application/text' }, [body || '']]
      end

      # write_content_security_policy will attempt to add an exemption to our
      # embedded javascript if the script-src policy is enabled.
      def write_content_security_policy(headers)
        csp = headers['Content-Security-Policy']

        # no csp, no worries
        return if csp.nil?

        new_csp = []
        policies = csp.split(';')
        policies.each do |policy|
          policy_type, *tokens = policy.strip.split(/\s/)
          policy_is_script_src = (policy_type == SCRIPT_SRC)
          unsafe_inline_missing = !tokens.include?(UNSAFE_INLINE)

          tokens.push(UNSAFE_INLINE) if policy_is_script_src && unsafe_inline_missing
          new_csp.push("#{policy_type} #{tokens.join(' ')};")
        end

        headers['Content-Security-Policy'] = new_csp.join(' ')
      end

      def do_html_injection(body)
        document = Nokogiri::HTML(body)

        head = document.at('head') || document.at('html').add_child('<head/>').first
        head.add_child('<style/>').first.content = embedded_css

        body = document.at('body') || document.at('html').add_child('<body/>').first
        body.add_child(embedded_html)
        body.add_child('<script/>').first.content = embedded_javascript

        document.serialize
      end

      def html_response?(headers)
        headers['Content-Type'] && headers['Content-Type'] =~ /html/
      end

      def config
        @config ||= AppMap::Config.load_from_file 'appmap.yml'
      end

      def public_path
        @public_path ||= Pathname.new(File.expand_path('../../../public', __dir__))
      end

      def embedded_javascript
        @embedded_javascript ||= File.read(public_path.join('appmap.js'))
      end

      def embedded_html
        @embedded_html ||= File.read(public_path.join('appmap.html'))
      end

      def embedded_css
        @embedded_css ||= File.read(public_path.join('appmap.css'))
      end

      def recording?
        !@event_thread.nil?
      end

      def appland_url
        ENV['APPLAND_URL']
      end
    end
  end
end
