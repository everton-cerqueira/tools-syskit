module Syskit
    module GUI
        # Widget that represents the app state and gives control over it
        class AppControl < Qt::Widget
            include Roby::Hooks
            include Roby::Hooks::InstanceHooks

            # The interface object that gives us access to the app
            #
            # @return [Roby::Interface::Async::Interface]
            attr_reader :syskit

            # The connection to the log stream
            attr_reader :syskit_log_stream

            # The Qt actions available for app control
            attr_reader :actions

            # The label on which we display the state
            attr_reader :connection_state

            # The subcommand object that gives us control over a replay app
            #
            # @return [nil,Roby::Interface::ClientSubcommand]
            attr_reader :replay

            # The name of the remote app
            def remote_name
                syskit.remote_name
            end

            # Whether we are working in live or replay modes
            def replay_mode?
                !!@replay
            end

            # @!group Hooks

            # Forward of {#syskit}'s on_reachable
            define_hooks :on_reachable
            # Forward of {#syskit}'s on_unreachable
            define_hooks :on_unreachable
            # Forward of {#syskit}'s on_job
            define_hooks :on_job
            # Called for each cycle update after the initialization phase
            define_hooks :on_log_reachable
            define_hooks :on_log_update

            # @!endgroup Hooks

            def initialize(syskit, parent = nil)
                super(parent)

                @syskit = syskit

                @connection_state = GlobalStateLabel.new(name: remote_name)
                connection_state.declare_state 'LIVE', :green
                connection_state.declare_state 'REPLAY', :green
                connection_state.declare_state 'UNREACHABLE', :red
                connect self, SIGNAL('progress(QString)') do |message|
                    state = connection_state.current_state.to_s
                    full_message = "%s - %s" % [state, message]
                    if !syskit_log_stream || syskit_log_stream.init_done?
                        if replay_mode? && (logical_time = replay.time)
                            logical_time_s = "#{logical_time.strftime('%H:%M:%S')}.#{'%.03i' % [logical_time.tv_usec / 1000]}"
                            full_message = "%s<br>&nbsp;&nbsp;RT: %s<br>&nbsp;&nbsp;LG: %s" % [state, message, logical_time_s]
                        end
                    end
                    connection_state.update_text(full_message)
                end

                @layout = Qt::VBoxLayout.new(self)
                layout.add_widget connection_state

                @actions = Hash.new
                action = actions[:start]   = Qt::Action.new("Start", self)
                connect action, SIGNAL('triggered()') do
                    app_start
                end
                action = actions[:restart] = Qt::Action.new("Restart", self)
                connect action, SIGNAL('triggered()') do
                    app_restart
                end
                action = actions[:quit]    = Qt::Action.new("Quit", self)
                connect action, SIGNAL('triggered()') do
                    app_quit
                end

                syskit.on_reachable do
                    update_log_server_connection(syskit.client.log_server_port)
                    @replay =
                        if syskit.client.has_subcommand?('replay')
                            syskit.client.subcommand('replay')
                        end
                    actions[:start].visible = false
                    actions[:restart].visible = true
                    actions[:quit].visible = true
                    if replay_mode?
                        connection_state.update_state 'REPLAY'
                    else
                        connection_state.update_state 'LIVE'
                    end
                    emit connection_state_changed(connection_state.current_state.to_s)

                    run_hook :on_reachable
                end

                syskit.on_unreachable do
                    if remote_name == 'localhost'
                        actions[:start].visible = true
                    end
                    actions[:restart].visible = false
                    actions[:quit].visible = false
                    connection_state.update_state 'UNREACHABLE'
                    emit connection_state_changed(connection_state.current_state.to_s)

                    run_hook :on_unreachable
                end

                syskit.on_job do |*args|
                    run_hook :on_job, *args
                end
            end

            def app_start
                robot_name, start_controller = AppStartDialog.exec(Roby.app.robots.names, self)
                if robot_name
                    extra_args = Array.new
                    if !robot_name.empty?
                        extra_args << "-r#{robot_name}"
                    end
                    if start_controller
                        extra_args << "-c"
                    end
                    Kernel.spawn Gem.ruby, '-S', 'syskit', 'run', *extra_args,
                        pgroup: true
                end
            end

            def app_quit
                syskit.quit
            end

            def app_restart
                syskit.restart
            end

            signals 'progress(QString)'
            signals 'connection_state_changed(QString)'

            def update_log_server_connection(port)
                if syskit_log_stream && (syskit_log_stream.port == port)
                    return
                elsif syskit_log_stream
                    syskit_log_stream.close
                end
                @syskit_log_stream = Roby::Interface::Async::Log.new(syskit.remote_name, port: port)
                syskit_log_stream.on_reachable do
                    run_hook :on_log_reachable
                end
                syskit_log_stream.on_init_progress do |rx, expected|
                    emit progress("loading %02i" % [Float(rx) / expected * 100])
                end
                syskit_log_stream.on_update do |cycle_index, cycle_time|
                    if syskit_log_stream.init_done?
                        time_s = "#{cycle_time.strftime('%H:%M:%S')}.#{'%.03i' % [cycle_time.tv_usec / 1000]}"
                        emit progress("@%i %s" % [cycle_index, time_s])
                        run_hook :on_log_update, cycle_index, cycle_time
                    end
                    syskit_log_stream.clear_integrated
                end
            end

        end
    end
end
