require 'syskit'
require 'roby/interface/async'
require 'roby/interface/async/log'
require 'syskit/gui/app_control'
require 'syskit/gui/job_status_display'
require 'syskit/gui/widget_list'
require 'syskit/gui/expanded_job_status'
require 'syskit/gui/global_state_label'
require 'syskit/gui/app_start_dialog'

module Syskit
    module GUI
        # UI that displays and allows to control jobs
        class RuntimeState < Qt::Widget
            # The AppControl object that maintains and displays the connection to the app
            attr_reader :app_control
            # The syskit connection object
            def syskit
                app_control.syskit
            end
            # The syskit log stream
            def syskit_log_stream
                app_control.syskit_log_stream
            end

            # The toplevel layout
            attr_reader :main_layout
            # The layout used to organize the widgets to create new jobs
            attr_reader :new_job_layout
            # The [WidgetList] widget in which we display the
            # summary of job status
            attr_reader :job_status_list
            # The [ExpandedJobStatus] widget in which we display expanded job
            # information
            attr_reader :job_expanded_status
            # The combo box used to create new jobs
            attr_reader :action_combo
            # The job that is currently selected
            attr_reader :current_job

            # All known tasks
            attr_reader :all_tasks
            # Job information for tasks in the rebuilt plan
            attr_reader :all_job_info

            # The name service which allows us to resolve Rock task contexts
            attr_reader :name_service
            # A task inspector widget we use to display the task states
            attr_reader :ui_task_inspector
            # The list of task names of the task currently displayed by the task
            # inspector
            attr_reader :current_orocos_tasks

            class ActionListDelegate < Qt::StyledItemDelegate
                OUTER_MARGIN = 5
                INTERLINE    = 3
                def sizeHint(option, index)
                    fm = option.font_metrics
                    main = index.data.toString
                    doc = index.data(Qt::UserRole).to_string || ''
                    Qt::Size.new(
                        [fm.width(main), fm.width(doc)].max + 2 * OUTER_MARGIN,
                        fm.height * 2 + OUTER_MARGIN * 2 + INTERLINE)
                end

                def paint(painter, option, index)
                    painter.save

                    if (option.state & Qt::Style::State_Selected) != 0
                        painter.fill_rect(option.rect, option.palette.highlight)
                        painter.brush = option.palette.highlighted_text
                    end

                    main = index.data.toString
                    doc = index.data(Qt::UserRole).to_string || ''
                    text_bounds = Qt::Rect.new

                    fm = option.font_metrics
                    painter.draw_text(
                        Qt::Rect.new(option.rect.x + OUTER_MARGIN, option.rect.y + OUTER_MARGIN, option.rect.width - 2 * OUTER_MARGIN, fm.height),
                        Qt::AlignLeft, main, text_bounds)

                    font = painter.font
                    font.italic = true
                    painter.font = font
                    painter.draw_text(
                        Qt::Rect.new(option.rect.x + OUTER_MARGIN, text_bounds.bottom + INTERLINE, option.rect.width - 2 * OUTER_MARGIN, fm.height),
                        Qt::AlignLeft, doc, text_bounds)
                ensure
                    painter.restore
                end
            end

            # @param [Roby::Interface::Async::Interface] syskit the underlying
            #   syskit interface
            # @param [Integer] poll_period how often should the syskit interface
            #   be polled (milliseconds). Set to nil if the polling is already
            #   done externally
            def initialize(parent: nil, syskit: Roby::Interface::Async::Interface.new, poll_period: 10)
                super(parent)

                orocos_corba_nameservice = Orocos::CORBA::NameService.new(syskit.remote_name)
                @name_service = Orocos::Async::NameService.new(orocos_corba_nameservice)

                @replay = nil

                if poll_period
                    poll_syskit_interface(syskit, poll_period)
                end

                @app_control = AppControl.new(syskit, self)
                create_ui

                @current_job = nil
                @current_orocos_tasks = Set.new
                @all_tasks = Set.new
                @all_job_info = Hash.new

                connect app_control, SIGNAL('progress(QString)'),
                    self, SIGNAL('progress(QString)')
                connect app_control, SIGNAL('connection_state_changed(QString)'),
                    self, SIGNAL('connection_state_changed(QString)')
                app_control.on_reachable do
                    action_combo.clear
                    syskit.actions.sort_by(&:name).each do |action|
                        next if action.advanced?
                        action_combo.add_item(action.name, Qt::Variant.new(action.doc))
                    end
                end
                app_control.on_log_reachable do
                    deselect_job
                end
                app_control.on_log_update do |cycle_index, cycle_time|
                    job_expanded_status.update_time(cycle_index, cycle_time)
                    update_tasks_info
                    job_expanded_status.add_tasks_info(all_tasks, all_job_info)
                    job_expanded_status.scheduler_state = syskit_log_stream.scheduler_state
                    job_expanded_status.update_chronicle
                end
                app_control.on_job do |job|
                    job.start
                    monitor_job(job)
                end
            end

            signals 'progress(QString)'
            signals 'connection_state_changed(QString)'

            def update_tasks_info
                if current_job
                    job_task = syskit_log_stream.plan.find_tasks(Roby::Interface::Job).
                        with_arguments(job_id: current_job.job_id).
                        first
                    return if !job_task
                    placeholder_task = job_task.planned_task
                    return if !placeholder_task

                    dependency = placeholder_task.relation_graph_for(Roby::TaskStructure::Dependency)
                    tasks = dependency.enum_for(:depth_first_visit, placeholder_task).to_a
                    tasks << job_task
                else
                    tasks = syskit_log_stream.plan.tasks
                end

                all_tasks.merge(tasks.to_set)
                tasks.each do |job|
                    if job.kind_of?(Roby::Interface::Job)
                        if placeholder_task = job.planned_task
                            all_job_info[placeholder_task] = job
                        end
                    end
                end
                update_orocos_tasks
            end

            def update_orocos_tasks
                orocos_tasks = all_tasks.map { |t| t.arguments[:orocos_name] }.compact.to_set
                removed = current_orocos_tasks - orocos_tasks
                new     = orocos_tasks - current_orocos_tasks
                removed.each do |task_name|
                    ui_task_inspector.remove_task(task_name)
                end
                new.each do |task_name|
                    ui_task_inspector.add_task(name_service.proxy(task_name))
                end
                @current_orocos_tasks = orocos_tasks
            end

            def create_ui
                job_summary = Qt::Widget.new
                job_summary_layout = Qt::VBoxLayout.new(job_summary)
                job_summary_layout.add_layout(@new_job_layout  = create_ui_new_job)
                job_summary_layout.add_widget(@job_status_list = WidgetList.new(self))

                job_status_list.add_widget app_control
                app_control.connect(SIGNAL('clicked()')) do
                    deselect_job
                end

                main_layout = Qt::VBoxLayout.new(self)
                splitter = Qt::Splitter.new
                splitter.add_widget job_summary
                splitter.add_widget(@job_expanded_status = ExpandedJobStatus.new)
                splitter.add_widget(@ui_task_inspector = Vizkit.default_loader.TaskInspector)
                job_expanded_status.set_size_policy(Qt::SizePolicy::MinimumExpanding, Qt::SizePolicy::MinimumExpanding)
                main_layout.add_widget splitter
                w = splitter.size.width
                splitter.sizes = [Integer(w * 0.25), Integer(w * 0.50), Integer(w * 0.25)]
            end

            def create_ui_new_job
                new_job_layout = Qt::HBoxLayout.new
                label   = Qt::Label.new("New Job", self)
                label.set_size_policy(Qt::SizePolicy::Minimum, Qt::SizePolicy::Minimum)
                @action_combo = Qt::ComboBox.new(self)
                action_combo.item_delegate = ActionListDelegate.new(self)
                new_job_layout.add_widget label
                new_job_layout.add_widget action_combo, 1
                action_combo.connect(SIGNAL('activated(QString)')) do |action_name|
                    create_new_job(action_name)
                end
                new_job_layout
            end

            class NewJobDialog < Qt::Dialog
                attr_reader :editor

                def initialize(parent = nil, text = '')
                    super(parent)
                    layout = Qt::VBoxLayout.new(self)
                    @editor = Qt::TextEdit.new(self)
                    layout.add_widget editor
                    self.text = text
                end

                def self.exec(parent, text)
                    new(parent, text).exec
                end

                def text=(text)
                    editor.plain_text = text
                end

                def text
                    editor.plain_text
                end
            end

            def create_new_job(action_name)
                action_model = syskit.actions.find { |m| m.name == action_name }
                if !action_model
                    raise ArgumentError, "no action named #{action_name} found"
                end

                if action_model.arguments.empty?
                    syskit.client.send("#{action_name}!", Hash.new)
                else
                    formatted_action = Array.new
                    formatted_action << "#{action_name}("
                    action_model.arguments.each do |arg|
                        formatted_action << "  # #{arg.doc}"
                        formatted_action << "  #{arg.name}: #{arg.default},"
                    end
                    formatted_action << ")"
                    NewJobDialog.exec(self, formatted_action.join("\n"))
                end
            end

            attr_reader :syskit_poll

            # @api private
            #
            # Sets up polling on a given syskit interface
            def poll_syskit_interface(syskit, period)
                @syskit_poll = Qt::Timer.new
                syskit_poll.connect(SIGNAL('timeout()')) do
                    syskit.poll
                    if syskit_log_stream
                        if syskit_log_stream.poll(max: 0.05) == Roby::Interface::Async::Log::STATE_PENDING_DATA
                            syskit_poll.interval = 0
                        else
                            syskit_poll.interval = period
                        end
                    end
                end
                syskit_poll.start(period)
                syskit
            end

            # @api private
            #
            # Create the UI elements for the given job
            #
            # @param [Roby::Interface::Async::JobMonitor] job
            def monitor_job(job)
                job_status = JobStatusDisplay.new(job)
                job_status_list.add_widget job_status
                job_status.connect(SIGNAL('clicked()')) do
                    select_job(job_status)
                end
                connect(job_status, SIGNAL('fileOpenClicked(const QUrl&)'),
                        self, SIGNAL('fileOpenClicked(const QUrl&)'))
            end

            def deselect_job
                @current_job = nil
                job_expanded_status.deselect
                all_tasks.clear
                all_job_info.clear
                if syskit_log_stream
                    update_tasks_info
                end
                job_expanded_status.add_tasks_info(all_tasks, all_job_info)
            end

            def select_job(job_status)
                @current_job = job_status.job
                all_tasks.clear
                all_job_info.clear
                update_tasks_info
                job_expanded_status.select(job_status)
                job_expanded_status.add_tasks_info(all_tasks, all_job_info)
            end

            signals 'fileOpenClicked(const QUrl&)'
        end
    end
end

