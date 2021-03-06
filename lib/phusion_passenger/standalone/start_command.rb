#  Phusion Passenger - https://www.phusionpassenger.com/
#  Copyright (c) 2010-2014 Phusion
#
#  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.

require 'optparse'
require 'thread'
PhusionPassenger.require_passenger_lib 'constants'
PhusionPassenger.require_passenger_lib 'ruby_core_enhancements'
PhusionPassenger.require_passenger_lib 'standalone/command'
PhusionPassenger.require_passenger_lib 'standalone/config_utils'
PhusionPassenger.require_passenger_lib 'utils/tmpio'

# We lazy load as many libraries as possible not only to improve startup performance,
# but also to ensure that we don't require libraries before we've passed the dependency
# checking stage of the runtime installer.

module PhusionPassenger
module Standalone

class StartCommand < Command
	def self.create_default_options
		return {
			:environment       => ENV['RAILS_ENV'] || ENV['RACK_ENV'] || ENV['NODE_ENV'] ||
				ENV['PASSENGER_APP_ENV'] || 'development',
			:spawn_method      => Kernel.respond_to?(:fork) ? DEFAULT_SPAWN_METHOD : 'direct',
			:engine            => "builtin",
			:nginx_version     => PREFERRED_NGINX_VERSION,
			:log_level         => DEFAULT_LOG_LEVEL
		}
	end

	def run
		load_local_config_file
		parse_options
		sanity_check_options_and_set_defaults

		lookup_runtime_and_ensure_installed
		set_stdout_stderr_binmode
		exit if @options[:runtime_check_only]

		find_apps
		find_pid_and_log_file(@app_finder, @options)
		create_working_dir
		begin
			initialize_vars
			start_engine
			show_intro_message
			maybe_daemonize
			touch_temp_dir_in_background
			########################
			########################
			watch_log_files_in_background if should_watch_logs?
			wait_until_engine_has_exited if should_wait_until_engine_has_exited?
		rescue Interrupt
			shutdown_and_cleanup(true)
			exit 2
		rescue SignalException => signal
			shutdown_and_cleanup(true)
			if signal.message == 'SIGINT' || signal.message == 'SIGTERM'
				exit 2
			else
				raise
			end
		rescue Exception
			shutdown_and_cleanup(true)
			raise
		else
			shutdown_and_cleanup(false)
		end
	end

private
	################# Configuration loading, option parsing and initialization ###################

	def self.create_option_parser(options)
		# If you add or change an option, make sure to update the following places too:
		# lib/phusion_passenger/standalone/start_command/builtin_engine.rb, #build_daemon_controller_options
		# resources/templates/config/standalone.erb
		OptionParser.new do |opts|
			nl = "\n" + ' ' * 37
			opts.banner = "Usage: passenger start [DIRECTORY] [OPTIONS]\n"
			opts.separator "Starts #{PROGRAM_NAME} Standalone and serve one or more web applications."
			opts.separator ""

			opts.separator "Server options:"
			opts.on("-a", "--address HOST", String, "Bind to the given address.#{nl}" +
				"Default: 0.0.0.0") do |value|
				options[:address] = value
			end
			opts.on("-p", "--port NUMBER", Integer,
				"Use the given port number. Default: 3000") do |value|
				options[:port] = value
			end
			opts.on("-S", "--socket FILE", String,
				"Bind to Unix domain socket instead of TCP#{nl}" +
				"socket") do |value|
				options[:socket_file] = value
			end
			opts.on("--ssl", "Enable SSL support (Nginx#{nl}" +
				"engine only)") do
				options[:ssl] = true
			end
			opts.on("--ssl-certificate PATH", String,
				"Specify the SSL certificate path#{nl}" +
				"(Nginx engine only)") do |value|
				options[:ssl_certificate] = File.absolute_path_no_resolve(value)
			end
			opts.on("--ssl-certificate-key PATH", String,
				"Specify the SSL key path") do |value|
				options[:ssl_certificate_key] = File.absolute_path_no_resolve(value)
			end
			opts.on("--ssl-port PORT", Integer,
				"Listen for SSL on this port, while#{nl}" +
				"listening for HTTP on the normal port#{nl}" +
				"(Nginx engine only)") do |value|
				options[:ssl_port] = value
			end
			opts.on("-d", "--daemonize", "Daemonize into the background") do
				options[:daemonize] = true
			end
			opts.on("--user USERNAME", String, "User to run as. Ignored unless#{nl}" +
				"running as root") do |value|
				options[:user] = value
			end
			opts.on("--log-file FILENAME", String,
				"Where to write log messages. Default:#{nl}" +
				"console, or /dev/null when daemonized") do |value|
				options[:log_file] = value
			end
			opts.on("--pid-file FILENAME", String, "Where to store the PID file") do |value|
				options[:pid_file] = value
			end
			opts.on("--instance-registry-dir PATH", String,
				"Use the given instance registry directory") do |value|
				options[:instance_registry_dir] = value
			end
			opts.on("--data-buffer-dir PATH", String,
				"Use the given data buffer directory") do |value|
				options[:data_buffer_dir] = value
			end

			opts.separator ""
			opts.separator "Application loading options:"
			opts.on("-e", "--environment ENV", String,
				"Framework environment.#{nl}" +
				"Default: #{options[:environment]}") do |value|
				options[:environment] = value
			end
			opts.on("-R", "--rackup FILE", String,
				"Consider application a Ruby app, and use#{nl}" +
				"the given rackup file") do |value|
				options[:app_type] = "rack"
				options[:startup_file] = value
			end
			opts.on("--app-type NAME", String,
				"Force app to be detected as the given type") do |value|
				options[:app_type] = value
			end
			opts.on("--startup-file FILENAME", String,
				"Force given startup file to be used") do |value|
				options[:startup_file] = value
			end
			opts.on("--spawn-method NAME", String,
				"The spawn method to use. Default: #{options[:spawn_method]}") do |value|
				options[:spawn_method] = value
			end
			opts.on("--static-files-dir PATH", String,
				"Specify the static files dir (Nginx engine#{nl}" +
				"only)") do |val|
				options[:static_files_dir] = File.absolute_path_no_resolve(val)
			end
			opts.on("--restart-dir PATH", String, "Specify the restart dir") do |val|
				options[:restart_dir] = File.absolute_path_no_resolve(val)
			end
			opts.on("--friendly-error-pages", "Turn on friendly error pages") do
				options[:friendly_error_pages] = true
			end
			opts.on("--no-friendly-error-pages", "Turn off friendly error pages") do
				options[:friendly_error_pages] = false
			end
			opts.on("--load-shell-envvars",
				"Load shell startup files before loading#{nl}" +
				"application") do
				options[:load_shell_envvars] = true
			end

			opts.separator ""
			opts.separator "Process management options:"
			opts.on("--max-pool-size NUMBER", Integer,
				"Maximum number of application processes.#{nl}" +
				"Default: #{DEFAULT_MAX_POOL_SIZE}") do |value|
				options[:max_pool_size] = value
			end
			opts.on("--min-instances NUMBER", Integer,
				"Minimum number of processes per#{nl}" +
				"application. Default: 1") do |value|
				options[:min_instances] = value
			end
			opts.on("--concurrency-model NAME", String,
				"The concurrency model to use, either#{nl}" +
				"'process' or 'thread' (Enterprise only).#{nl}" +
				"Default: #{DEFAULT_CONCURRENCY_MODEL}") do |value|
				options[:concurrency_model] = value
			end
			opts.on("--thread-count NAME", Integer,
				"The number of threads to use when using#{nl}" +
				"the 'thread' concurrency model (Enterprise#{nl}" +
				"only). Default: #{DEFAULT_APP_THREAD_COUNT}") do |value|
				options[:thread_count] = value
			end
			opts.on("--rolling-restarts", "Enable rolling restarts (Enterprise only)") do
				options[:rolling_restarts] = true
			end
			opts.on("--resist-deployment-errors", "Enable deployment error resistance#{nl}" +
				"(Enterprise only)") do
				options[:resist_deployment_errors] = true
			end

			opts.separator ""
			opts.separator "Request handling options:"
			opts.on("--sticky-sessions", "Enable sticky sessions") do
				options[:sticky_sessions] = true
			end
			opts.on("--sticky-sessions-cookie-name", String,
				"Cookie name to use for sticky sessions.#{nl}" +
				"Default: #{DEFAULT_STICKY_SESSIONS_COOKIE_NAME}") do |value|
				options[:sticky_sessions_cookie_name] = value
			end

			opts.separator ""
			opts.separator "Union Station options:"
			opts.on("--union-station-gateway HOST:PORT", String,
				"Specify Union Station Gateway host and port") do |value|
				host, port = value.split(":", 2)
				port = port.to_i
				port = 443 if port == 0
				options[:union_station_gateway_address] = host
				options[:union_station_gateway_port] = port.to_i
			end
			opts.on("--union-station-key KEY", String, "Specify Union Station key") do |value|
				options[:union_station_key] = value
			end

			opts.separator ""
			opts.separator "Nginx engine options:"
			opts.on("--nginx-bin FILENAME", String, "Nginx binary to use as core") do |value|
				options[:nginx_bin] = value
			end
			opts.on("--nginx-version VERSION", String,
				"Nginx version to use as core.#{nl}" +
				"Default: #{PREFERRED_NGINX_VERSION}") do |value|
				options[:nginx_version] = value
			end
			opts.on("--nginx-tarball FILENAME", String,
				"If Nginx needs to be installed, then the#{nl}" +
				"given tarball will be used instead of#{nl}" +
				"downloading from the Internet") do |value|
				options[:nginx_tarball] = File.absolute_path_no_resolve(value)
			end
			opts.on("--nginx-config-template FILENAME", String,
				"The template to use for generating the#{nl}" +
				"Nginx config file") do |value|
				options[:nginx_config_template] = File.absolute_path_no_resolve(value)
			end

			opts.separator ""
			opts.separator "Advanced options:"
			opts.on("--engine NAME", String,
				"Underlying HTTP engine to use. Available#{nl}" +
				"options: builtin (default), nginx") do |value|
				options[:engine] = value
			end
			opts.on("--log-level NUMBER", Integer, "Log level to use. Default: #{DEFAULT_LOG_LEVEL}") do |value|
				options[:log_level] = value
			end
			opts.on("--binaries-url-root URL", String,
				"If Nginx needs to be installed, then the#{nl}" +
				"specified URL will be checked for binaries#{nl}" +
				"prior to a local build") do |value|
				options[:binaries_url_root] = value
			end
			opts.on("--no-download-binaries", "Never download binaries") do
				options[:download_binaries] = false
			end
			opts.on("--runtime-check-only",
				"Quit after checking whether the#{nl}" +
				"#{PROGRAM_NAME} Standalone runtime files#{nl}" +
				"are installed") do
				options[:runtime_check_only] = true
			end
			opts.on("--no-install-runtime", "Abort if runtime must be installed") do
				options[:dont_install_runtime] = true
			end
			opts.on("--no-compile-runtime", "Abort if runtime must be compiled") do
				options[:dont_compile_runtime] = true
			end
		end
	end

	def load_local_config_file
		if @argv.empty?
			app_dir = File.absolute_path_no_resolve(".")
		elsif @argv.size == 1
			app_dir = @argv[0]
		end
		if app_dir
			begin
				ConfigUtils.load_local_config_file!(app_dir, @options)
			rescue ConfigLoadError => e
				abort "*** ERROR: #{e.message}"
			end
		end
	end

	def sanity_check_options_and_set_defaults
		if (@options[:address] || @options[:port]) && @options[:socket_file]
			abort "You cannot specify both --address/--port and --socket. Please choose either one."
		end
		if @options[:ssl] && !@options[:ssl_certificate]
			abort "You specified --ssl. Please specify --ssl-certificate as well."
		end
		if @options[:ssl] && !@options[:ssl_certificate_key]
			abort "You specified --ssl. Please specify --ssl-certificate-key as well."
		end
		if @options[:engine] != "builtin" && @options[:engine] != "nginx"
			abort "You've specified an invalid value for --engine. The only values allowed are: builtin, nginx."
		end

		if !@options[:socket_file]
			@options[:address] ||= "0.0.0.0"
			@options[:port] ||= 3000
		end

		if @options[:engine] == "builtin"
			# We explicitly check for some options are set and warn the user about this,
			# in case they forget to pass --engine=nginx. We don't warn about options
			# that begin with --nginx- because that should be obvious.
			check_nginx_option_used_with_builtin_engine(:ssl, "--ssl")
			check_nginx_option_used_with_builtin_engine(:ssl_certificate, "--ssl-certificate")
			check_nginx_option_used_with_builtin_engine(:ssl_certificate_key, "--ssl-certificate-key")
			check_nginx_option_used_with_builtin_engine(:ssl_port, "--ssl-port")
			check_nginx_option_used_with_builtin_engine(:static_files_dir, "--static-files-dir")
		end

		#############
	end

	def check_nginx_option_used_with_builtin_engine(option, argument)
		if @options.has_key?(option)
			STDERR.puts "*** Warning: the #{argument} option is only allowed if you use " +
				"the 'nginx' engine. You are currently using the 'builtin' engine, so " +
				"this option has been ignored. To switch to the Nginx engine, please " +
				"pass --engine=nginx."
		end
	end

	def lookup_runtime_and_ensure_installed
		@agent_exe = PhusionPassenger.find_support_binary(AGENT_EXE)
		if @options[:nginx_bin]
			@nginx_binary = @options[:nginx_bin]
			if !@nginx_binary
				abort "*** ERROR: Nginx binary #{@options[:nginx_bin]} does not exist"
			end
			if !@agent_exe
				install_runtime
				@agent_exe = PhusionPassenger.find_support_binary(AGENT_EXE)
			end
		else
			nginx_name = "nginx-#{@options[:nginx_version]}"
			@nginx_binary = PhusionPassenger.find_support_binary(nginx_name)
			if !@agent_exe || !@nginx_binary
				install_runtime
				@agent_exe = PhusionPassenger.find_support_binary(AGENT_EXE)
				@nginx_binary = PhusionPassenger.find_support_binary(nginx_name)
			end
		end
	end

	def install_runtime
		if @options[:dont_install_runtime]
			abort "*** ERROR: Refusing to install the #{PROGRAM_NAME} Standalone runtime " +
				"because --no-install-runtime is given."
		end

		args = ["--brief", "--no-force-tip"]
		if @options[:binaries_url_root]
			args << "--url-root"
			args << @options[:binaries_url_root]
		end
		if @options[:nginx_version]
			args << "--nginx-version"
			args << @options[:nginx_version]
		end
		if @options[:nginx_tarball]
			args << "--nginx-tarball"
			args << @options[:nginx_tarball]
		end
		if @options[:dont_compile_runtime]
			args << "--no-compile"
		end
		PhusionPassenger.require_passenger_lib 'config/install_standalone_runtime_command'
		PhusionPassenger::Config::InstallStandaloneRuntimeCommand.new(args).run
		puts
		puts "--------------------------"
		puts
	end

	def set_stdout_stderr_binmode
		# We already set STDOUT and STDERR to binmode in bin/passenger, which
		# fixes https://github.com/phusion/passenger-ruby-heroku-demo/issues/11.
		# However RuntimeInstaller sets them to UTF-8, so here we set them back.
		STDOUT.binmode
		STDERR.binmode
	end


	################## Core logic ##################

	def find_apps
		PhusionPassenger.require_passenger_lib 'standalone/app_finder'
		@app_finder = AppFinder.new(@argv, @options)
		@apps = @app_finder.scan
		if @app_finder.multi_mode? && @options[:engine] != 'nginx'
			puts "Mass deployment enabled, so forcing engine to 'nginx'."
			@options[:engine] = 'nginx'
		end
	end

	def find_pid_and_log_file(app_finder, options)
		exec_root = app_finder.execution_root
		if options[:socket_file]
			pid_basename = "passenger.pid"
			log_basename = "passenger.log"
		else
			pid_basename = "passenger.#{options[:port]}.pid"
			log_basename = "passenger.#{options[:port]}.log"
		end
		if File.directory?("#{exec_root}/tmp/pids")
			options[:pid_file] ||= "#{exec_root}/tmp/pids/#{pid_basename}"
		else
			options[:pid_file] ||= "#{exec_root}/#{pid_basename}"
		end
		if File.directory?("log")
			options[:log_file] ||= "#{exec_root}/log/#{log_basename}"
		else
			options[:log_file] ||= "#{exec_root}/#{log_basename}"
		end
	end

	def create_working_dir
		# We don't remove the working dir in 'passenger start'. In daemon
		# mode 'passenger start' just quits and lets background processes
		# running. A specific background process, temp-dir-toucher, is
		# responsible for cleaning up the working dir.
		@working_dir = PhusionPassenger::Utils.mktmpdir("passenger-standalone.")
		File.chmod(0755, @working_dir)
		Dir.mkdir("#{@working_dir}/logs")
		@can_remove_working_dir = true
	end

	def initialize_vars
		@console_mutex = Mutex.new
		@termination_pipe = IO.pipe
		@threads = []
		@interruptable_threads = []
	end

	def start_engine
		metaclass = class << self; self; end
		if @options[:engine] == 'nginx'
			PhusionPassenger.require_passenger_lib 'standalone/start_command/nginx_engine'
			metaclass.send(:include, PhusionPassenger::Standalone::StartCommand::NginxEngine)
		else
			PhusionPassenger.require_passenger_lib 'standalone/start_command/builtin_engine'
			metaclass.send(:include, PhusionPassenger::Standalone::StartCommand::BuiltinEngine)
		end
		start_engine_real
	end

	# Returns the URL that the server will be listening on.
	def listen_url
		if @options[:socket_file]
			return @options[:socket_file]
		else
			if @options[:ssl] && !@options[:ssl_port]
				scheme = "https"
			else
				scheme = "http"
			end
			result = "#{scheme}://"
			if @options[:port] == 80
				result << @options[:address]
			else
				result << compose_ip_and_port(@options[:address], @options[:port])
			end
			result << "/"
			return result
		end
	end

	def compose_ip_and_port(ip, port)
		if ip =~ /:/
			# IPv6
			return "[#{ip}]:#{port}"
		else
			return "#{ip}:#{port}"
		end
	end

	def show_intro_message
		puts "=============== Phusion Passenger Standalone web server started ==============="
		puts "PID file: #{@options[:pid_file]}"
		puts "Log file: #{@options[:log_file]}"
		puts "Environment: #{@options[:environment]}"
		puts "Accessible via: #{listen_url}"

		puts
		if @options[:daemonize]
			puts "Serving in the background as a daemon."
		else
			puts "You can stop #{PROGRAM_NAME} Standalone by pressing Ctrl-C."
		end
		puts "Problems? Check #{STANDALONE_DOC_URL}#troubleshooting"
		puts "==============================================================================="
	end

	def maybe_daemonize
		if @options[:daemonize]
			PhusionPassenger.require_passenger_lib 'platform_info/ruby'
			if PlatformInfo.ruby_supports_fork?
				daemonize
			else
				abort "Unable to daemonize using the current Ruby interpreter " +
					"(#{PlatformInfo.ruby_command}) because it does not support forking."
			end
		end
	end

	def daemonize
		pid = fork
		if pid
			# Parent
			exit!(0)
		else
			# Child
			trap "HUP", "IGNORE"
			STDIN.reopen("/dev/null", "r")
			STDOUT.reopen(@options[:log_file], "a")
			STDERR.reopen(@options[:log_file], "a")
			STDOUT.sync = true
			STDERR.sync = true
			Process.setsid
			@threads = nil
		end
	end

	def touch_temp_dir_in_background
		result = system(@agent_exe,
			"temp-dir-toucher",
			@working_dir,
			"--cleanup",
			"--daemonize",
			"--pid-file", "#{@working_dir}/temp_dir_toucher.pid",
			"--log-file", @options[:log_file])
		if !result
			abort "Cannot start #{@agent_exe} temp-dir-toucher"
		end
		@can_remove_working_dir = false
	end

	def watch_log_file(log_file)
		if File.exist?(log_file)
			backward = 0
		else
			# tail bails out if the file doesn't exist, so wait until it exists.
			while !File.exist?(log_file)
				sleep 1
			end
			backward = 10
		end

		IO.popen("tail -f -n #{backward} \"#{log_file}\"", "rb") do |f|
			begin
				while true
					begin
						line = f.readline
						@console_mutex.synchronize do
							STDOUT.write(line)
							STDOUT.flush
						end
					rescue EOFError
						break
					end
				end
			ensure
				Process.kill('TERM', f.pid) rescue nil
			end
		end
	end

	def watch_log_files_in_background
		@apps.each do |app|
			thread = Thread.new do
				Thread.current.abort_on_exception = true
				watch_log_file("#{app[:root]}/log/#{@options[:environment]}.log")
			end
			@threads << thread
			@interruptable_threads << thread
		end
		thread = Thread.new do
			Thread.current.abort_on_exception = true
			watch_log_file(@options[:log_file])
		end
		@threads << thread
		@interruptable_threads << thread
	end

	def should_watch_logs?
		return !@options[:daemonize] && @options[:log_file] != "/dev/null"
	end

	def wait_until_engine_has_exited
		# Since the engine is not our child process (it daemonizes)
		# we cannot use Process.waitpid to wait for it. A busy-sleep-loop with
		# Process.kill(0, pid) isn't very efficient. Instead we do this:
		#
		# Connect to the engine's server and wait until it disconnects the socket
		# because of timeout. Keep doing this until we can no longer connect.
		while true
			if @options[:socket_file]
				socket = UNIXSocket.new(@options[:socket_file])
			else
				socket = TCPSocket.new(@options[:address], @options[:port])
			end
			begin
				socket.read rescue nil
			ensure
				socket.close rescue nil
			end
		end
	rescue Errno::ECONNREFUSED, Errno::ECONNRESET
	end

	def should_wait_until_engine_has_exited?
		return !@options[:daemonize] || @app_finder.multi_mode?
	end


	################## Shut down and cleanup ##################

	def shutdown_and_cleanup(error_occurred)
		# Stop engine
		if @engine && (error_occurred || should_wait_until_engine_has_exited?)
			@console_mutex.synchronize do
				STDOUT.write("Stopping web server...")
				STDOUT.flush
				@engine.stop
				STDOUT.puts " done"
				STDOUT.flush
			end
			@engine = nil
		end

		# Stop threads
		if @threads
			if !@termination_pipe[1].closed?
				@termination_pipe[1].write("x")
				@termination_pipe[1].close
			end
			@interruptable_threads.each do |thread|
				thread.terminate
			end
			@interruptable_threads = []
			@threads.each do |thread|
				thread.join
			end
			@threads = nil
		end

		if @can_remove_working_dir
			FileUtils.remove_entry_secure(@working_dir)
			@can_remove_working_dir = false
		end
	end
end

end # module Standalone
end # module PhusionPassenger
