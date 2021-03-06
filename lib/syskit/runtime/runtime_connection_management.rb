module Syskit
    module Runtime
        # Connection management at runtime
        class ConnectionManagement
            extend Logger::Hierarchy
            include Logger::Hierarchy

            attr_reader :plan

            attr_reader :dataflow_graph

            def scheduler
                plan.execution_engine.scheduler
            end

            def initialize(plan)
                @plan = plan
                @dataflow_graph = plan.task_relation_graph_for(Flows::DataFlow)
            end

            def self.update(plan)
                manager = ConnectionManagement.new(plan)
                manager.update
            end

            # Updates an intermediate graph (Syskit::RequiredDataFlow) where
            # we store the concrete connections. We don't try to be smart:
            # remove all tasks that have to be updated and add their connections
            # again
            def update_required_dataflow_graph(tasks)
                tasks = tasks.to_set

                # Remove first all tasks. Otherwise, removing some tasks will
                # also remove the new edges we just added
                for t in tasks
                    RequiredDataFlow.remove_vertex(t)
                end

                # Create the new connections
                # 
                # We're only updating on a partial set of tasks ... so we do
                # have to enumerate both output and input connections. We can
                # however avoid doulbing work by avoiding the update of sink
                # tasks that are part of the set
                for t in tasks
                    t.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                        RequiredDataFlow.add_connections(source_task, t, [source_port, sink_port] => policy)
                    end
                    t.each_concrete_output_connection do |source_port, sink_port, sink_task, policy|
                        next if tasks.include?(sink_task)
                        RequiredDataFlow.add_connections(t, sink_task, [source_port, sink_port] => policy)
                    end
                end
            end

            # Computes the connection changes that are required to make the
            # required connections (declared in the DataFlow relation) match the
            # actual ones (on the underlying modules)
            #
            # It returns nil if the change can't be computed because the Roby
            # tasks are not tied to an underlying RTT task context.
            #
            # Returns [new, removed] where
            #
            #   new = { [from_task, to_task] => { [from_port, to_port] => policy, ... }, ... }
            #
            # in which +from_task+ and +to_task+ are instances of
            # Syskit::TaskContext (i.e. Roby tasks), +from_port+ and
            # +to_port+ are the port names (i.e. strings) and policy the policy
            # hash that Orocos::OutputPort#connect_to expects.
            #
            #   removed = { [from_task, to_task] => { [from_port, to_port], ... }, ... }
            #
            # in which +from_task+ and +to_task+ are instances of
            # Orocos::TaskContext (i.e. the underlying RTT tasks). +from_port+ and
            # +to_port+ are the names of the ports that have to be disconnected
            # (i.e. strings)
            def compute_connection_changes(tasks)
                not_running = tasks.find_all { |t| !t.orocos_task }
                if !not_running.empty?
                    debug do
                        debug "not computing connections because the deployment of the following tasks is not yet ready"
                        tasks.each do |t|
                            debug "  #{t}"
                        end
                        break
                    end
                    return
                end

                update_required_dataflow_graph(tasks)
                new_edges, removed_edges, updated_edges =
                    RequiredDataFlow.difference(ActualDataFlow, tasks, &:orocos_task)

                new = Hash.new
                new_edges.each do |source_task, sink_task|
                    new[[source_task, sink_task]] = RequiredDataFlow.edge_info(source_task, sink_task)
                end

                removed = Hash.new
                removed_edges.each do |source_task, sink_task|
                    removed[[source_task, sink_task]] = ActualDataFlow.edge_info(source_task, sink_task).keys.to_set
                end

                # We have to work on +updated+. The graphs are between tasks,
                # not between ports because of how ports are handled on both the
                # orocos.rb and Roby sides. So we must convert the updated
                # mappings into add/remove pairs. Moreover, to update a
                # connection policy we need to disconnect and reconnect anyway.
                #
                # Note that it is fine from a performance point of view, as in
                # most cases one removes all connections from two components to
                # recreate other ones between other components
                updated_edges.each do |source_task, sink_task|
                    new_mapping = RequiredDataFlow.edge_info(source_task, sink_task)
                    old_mapping = ActualDataFlow.edge_info(source_task.orocos_task, sink_task.orocos_task)

                    new_connections     = Hash.new
                    removed_connections = Set.new
                    new_mapping.each do |ports, new_policy|
                        if old_policy = old_mapping[ports]
                            if old_policy != new_policy
                                new_connections[ports] = new_policy
                                removed_connections << ports
                            end
                        else
                            new_connections[ports] = new_policy
                        end
                    end
                    old_mapping.each_key do |ports|
                        if !new_mapping.has_key?(ports)
                            removed_connections << ports
                        end
                    end

                    if !new_connections.empty?
                        new[[source_task, sink_task]] = new_connections
                    end
                    if !removed_connections.empty?
                        removed[[source_task.orocos_task, sink_task.orocos_task]] = removed_connections
                    end
                end

                return new, removed
            end

            def find_setup_syskit_task_context_from_orocos_task(orocos_task)
                klass = TaskContext.model_for(orocos_task.model)
                task = plan.find_tasks(klass.concrete_model).not_finishing.not_finished.
                    find { |t| t.setup? && (t.orocos_task == orocos_task) }
            end

            # Checks whether the removal of some connections require to run the
            # Syskit deployer right away
            #
            # @param [{(Orocos::TaskContext,Orocos::TaskContext) => {[String,String] => Hash}}] removed
            #   the connections, specified between the actual tasks (NOT their Roby representations)
            def removed_connections_require_network_update?(connections)
                unneeded_tasks = nil
                handle_modified_task = lambda do |orocos_task|
                    if !(syskit_task = find_setup_syskit_task_context_from_orocos_task(orocos_task))
                        return false
                    end

                    unneeded_tasks ||= plan.unneeded_tasks
                    if !unneeded_tasks.include?(syskit_task)
                        return true
                    end
                end

                connections.each do |(source_task, sink_task), mappings|
                    mappings.each do |source_port, sink_port|
                        if ActualDataFlow.static?(source_task, source_port) && handle_modified_task[source_task]
                            debug { "#{source_task} has an outgoing connection removed from #{source_port} and the port is static" }
                            return true
                        elsif ActualDataFlow.static?(sink_task, sink_port) && handle_modified_task[sink_task]
                            debug { "#{sink_task} has an outgoing connection removed from #{sink_port} and the port is static" }
                            return true
                        end
                    end
                end
                false
            end

            def disconnect_actual_ports(source_task, source_port, sink_task, sink_port)
                source = source_task.port(source_port, false)
                sink   = sink_task.port(sink_port, false)

                if !source.disconnect_from(sink)
                    warn "while disconnecting #{source_task}:#{source_port} => #{sink_task}:#{sink_port} returned false"
                    warn "I assume that the ports are disconnected, but this should not have happened"
                end

            rescue Orocos::NotFound => e
                terminating_deployments =
                    plan.find_tasks(Syskit::Deployment).finishing.
                    flat_map { |d| d.task_handles.values }

                if !terminating_deployments.include?(source_task) && !terminating_deployments.include?(sink_task)
                    warn "error while disconnecting #{source_task}:#{source_port} => #{sink_task}:#{sink_port}: #{e.message}"
                    warn "I am assuming that the disconnection is actually effective, since one port does not exist anymore"
                end
            rescue Orocos::ComError => e
                terminating_deployments =
                    plan.find_tasks(Syskit::Deployment).finishing.
                    flat_map { |d| d.task_handles.values }

                if !terminating_deployments.include?(source_task) && !terminating_deployments.include?(sink_task)
                    warn "Communication error while disconnecting #{source_task}:#{source_port} => #{sink_task}:#{sink_port}: #{e.message}"
                    warn "I am assuming that the source component is dead and that therefore the connection is actually effective"
                end
            end
            
            # Remove port-to-port connections
            #
            # @param [{(Orocos::TaskContext,Orocos::TaskContext) => [[String,String]]}] removed
            #   the connections, specified between the actual tasks (NOT their Roby representations)
            # @return [[Syskit::TaskContext]] the list of tasks whose connections have been modified
            def apply_connection_removal(removed)
                modified = Set.new
                # Remove connections first
                removed.each do |(source_task, sink_task), mappings|
                    mappings.each do |source_port, sink_port|
                        debug do
                            debug "disconnecting #{source_task}:#{source_port}"
                            debug "     => #{sink_task}:#{sink_port}"
                            break
                        end

                        if syskit_source_task = find_setup_syskit_task_context_from_orocos_task(source_task)
                            syskit_source_task.removing_output_port_connection(source_port, sink_task, sink_port)
                        end
                        if syskit_sink_task = find_setup_syskit_task_context_from_orocos_task(sink_task)
                            syskit_sink_task.removing_input_port_connection(source_task, source_port, sink_port)
                        end

                        disconnect_actual_ports(source_task, source_port, sink_task, sink_port)

                        if syskit_source_task
                            syskit_source_task.removed_output_port_connection(source_port, sink_task, sink_port)
                        end
                        if syskit_sink_task
                            syskit_sink_task.removed_input_port_connection(source_task, source_port, sink_port)
                        end

                        if ActualDataFlow.static?(source_task, source_port)
                            TaskContext.needs_reconfiguration << source_task.name
                        end
                        if ActualDataFlow.static?(sink_task, sink_port)
                            TaskContext.needs_reconfiguration << sink_task.name
                        end
                        ActualDataFlow.remove_connections(source_task, sink_task,
                                          [[source_port, sink_port]])

                        if syskit_source_task && !syskit_source_task.executable?
                            modified << syskit_source_task
                        end
                        if syskit_sink_task && !syskit_sink_task.executable?
                            modified << syskit_sink_task
                        end
                    end
                end
                modified
            end

            # Actually create new connections
            #
            # @param [{(Syskit::TaskContext,Syskit::TaskContext) => {[String,String] => Hash}}] removed
            #   the connections, specified between the Syskit tasks
            # @return [[Syskit::TaskContext]] the list of tasks whose connections have been modified
            def apply_connection_additions(new)
                # And create the new ones
                pending_tasks = Set.new
                new.each do |(from_task, to_task), mappings|
                    next if !from_task.orocos_task || !to_task.orocos_task

                    mappings.each do |(from_port, to_port), policy|
                        debug do
                            debug "connecting #{from_task}:#{from_port}"
                            debug "     => #{to_task}:#{to_port}"
                            debug "     with policy #{policy}"
                            break
                        end

                        begin
                            policy, _ = Kernel.filter_options(policy, Orocos::Port::CONNECTION_POLICY_OPTIONS)

                            from_syskit_port = from_task.find_output_port(from_port)
                            to_syskit_port   = to_task.find_input_port(to_port)
                            from_orocos_port = from_task.orocos_task.port(from_port)
                            to_orocos_port   = to_task.orocos_task.port(to_port)

                            from_task.adding_output_port_connection(from_syskit_port, to_syskit_port, policy)
                            to_task.adding_input_port_connection(from_syskit_port, to_syskit_port, policy)

                            begin
                                current_policy = ActualDataFlow.edge_info(from_task.orocos_task, to_task.orocos_task)[[from_port, to_port]]
                            rescue ArgumentError
                            end

                            from_orocos_port.connect_to(to_orocos_port, policy)

                            from_task.added_output_port_connection(from_syskit_port, to_syskit_port, policy)
                            to_task.added_input_port_connection(from_syskit_port, to_syskit_port, policy)

                            ActualDataFlow.add_connections(
                                from_task.orocos_task, to_task.orocos_task,
                                [from_port, to_port] => [policy, from_syskit_port.static?, to_syskit_port.static?],
                                force_update: true)

                        rescue Orocos::ComError
                            # The task will be aborted. Simply ignore
                        rescue Orocos::InterfaceObjectNotFound => e
                            if e.task == from_task.orocos_task && e.name == from_port
                                plan.execution_engine.add_error(PortNotFound.new(from_task, from_port, :output))
                            else
                                plan.execution_engine.add_error(PortNotFound.new(to_task, to_port, :input))
                            end

                        end
                    end
                    if !to_task.executable?
                        pending_tasks << to_task
                    end
                end
                pending_tasks
            end

            def mark_connected_pending_tasks_as_executable(pending_tasks)
                pending_tasks.each do |t|
                    if t.setup? && t.all_inputs_connected?
                        t.executable = nil
                        debug { "#{t} has all its inputs connected, set executable to nil and executable? = #{t.executable?}" }
                        scheduler.report_action "all inputs connected, marking as executable", t

                    else
                        scheduler.report_holdoff "some inputs are not yet connected, Syskit maintains its state to non-executable", t
                        scheduler.report_action "some inputs are not yet connected, Syskit maintains its state to non-executable", t
                    end
                end
            end

            # Partition a set of connections between the ones that can be
            # performed right now, and those that must wait for the involved
            # tasks' state to change
            #
            # @param connections the connections, specified as
            #            (source_task, sink_task) => Hash[
            #               (source_port, sink_port) => policy,
            #               ...]
            #
            #   note that the source and sink task type are unspecified.
            #
            # @param [Hash<Object,Symbol>] a cache of the task states, as a
            #   mapping from a source/sink task object as used in the
            #   connections hash to the state name
            # @param [String] the kind of operation that will be done. It is
            #   purely used to display debugging information
            # @param [#[]] an object that maps the objects used as tasks in
            #   connections and states to an object that responds to
            #   {#rtt_state}, to evaluate the object's state.
            # @return [Array,Hash] the set of connections that can be performed
            #   right away, and the set of connections that require a state change
            #   in the tasks
            def partition_early_late(connections, states, kind, mapping)
                early, late = connections.partition do |(source_task, sink_task), port_pairs|
                    states[source_task] ||= begin mapping[source_task].rtt_state
                                            rescue Orocos::ComError
                                            end
                    states[sink_task]   ||= begin mapping[sink_task].rtt_state
                                            rescue Orocos::ComError
                                            end

                    early = (states[source_task] != :RUNNING) || (states[sink_task] != :RUNNING)
                    debug do
                        debug "#{port_pairs.size} #{early ? 'early' : 'late'} #{kind} connections from #{source_task} to #{sink_task}"
                        debug "  source state: #{states[source_task]}"
                        debug "  sink state: #{states[sink_task]}"
                        break
                    end
                    early
                end
                return early, Hash[late]
            end

            # Partition new connections between 
            def new_connections_partition_held_ready(new)
                additions_held, additions_ready = Hash.new, Hash.new
                new.each do |(from_task, to_task), mappings|
                    if !from_task.execution_agent.ready? || !to_task.execution_agent.ready?
                        hold, ready = mappings, Hash.new
                    elsif from_task.setup? && to_task.setup?
                        hold, ready = Hash.new, mappings
                    else
                        hold, ready = mappings.partition do |(from_port, to_port), policy|
                            (!from_task.setup? && !from_task.concrete_model.find_output_port(from_port)) ||
                                (!to_task.setup? && !to_task.concrete_model.find_input_port(to_port))
                        end
                    end

                    if !hold.empty?
                        debug do
                            debug "holding #{hold.size} connections from "
                            log_pp :debug, from_task
                            debug "  setup?: #{from_task.setup?}"
                            log_pp :debug, to_task
                            debug "  setup?: #{to_task.setup?}"

                            hold.each do |(from_port, to_port), policy|
                                debug "  #{from_port} => #{to_port} [#{policy}]"
                                if !from_task.setup? && !from_task.concrete_model.find_output_port(from_port)
                                    debug "    output port #{from_port} is dynamic and the task is not yet configured"
                                end
                                if !to_task.setup? && !to_task.concrete_model.find_input_port(to_port)
                                    debug "    input port #{to_port} is dynamic and the task is not yet configured"
                                end
                            end
                            break
                        end
                        additions_held[[from_task, to_task]] = Hash[hold]
                    end

                    if !ready.empty?
                        debug do
                            debug "ready on #{from_task} => #{to_task}"
                            ready.each do |(from_port, to_port), policy|
                                debug "  #{from_port} => #{to_port} [#{policy}]"
                            end
                            break
                        end
                        additions_ready[[from_task, to_task]] = Hash[ready]
                    end
                end
                return additions_held, additions_ready
            end

            # Apply the connection changes that can be applied
            def apply_connection_changes(new, removed)
                additions_held, additions_ready = new_connections_partition_held_ready(new)

                task_states = Hash.new
                early_removal, late_removal     =
                    partition_early_late(removed, task_states, 'removed', proc { |v| v })
                early_additions, late_additions =
                    partition_early_late(additions_ready, task_states, 'added', proc(&:orocos_task))

                modified_tasks = apply_connection_removal(early_removal)
                modified_tasks |= apply_connection_additions(early_additions)

                if !additions_held.empty?
                    mark_connected_pending_tasks_as_executable(modified_tasks)
                    additions = additions_held.merge(late_additions) { |key, mappings1, mappings2| mappings1.merge(mappings2) }
                    return additions, late_removal
                end

                modified_tasks |= apply_connection_removal(late_removal)
                modified_tasks |= apply_connection_additions(late_additions)
                mark_connected_pending_tasks_as_executable(modified_tasks)
                return Hash.new, Hash.new
            end

            # @api private
            #
            # Compute the set of connections we should remove to account for
            # orocos tasks whose supporting syskit task has been removed, but
            # are still connected
            #
            # The result is formatted as the rest of the connection hashes, that
            # is keys are (source_task, sink_task) and values are Array<(source_port,
            # task_port)>. Note that source_task and sink_task are
            # Orocos::TaskContext, and it is guaranteed that one of them has no
            # equivalent in the Syskit graphs (meaning that no keys in the
            # return value can be found in the return value of
            # {#compute_connection_changes})
            #
            # @return [Hash]
            def dangling_task_cleanup
                removed = Hash.new

                present_tasks = plan.find_tasks(TaskContext).inject(Hash.new) do |h, t|
                    h[t.orocos_task] = t
                    h
                end
                dangling_tasks = ActualDataFlow.each_vertex.find_all do |orocos_task|
                    !present_tasks.has_key?(orocos_task)
                end
                dangling_tasks.each do |parent_t|
                    ActualDataFlow.each_out_neighbour(parent_t) do |child_t|
                        mappings = ActualDataFlow.edge_info(parent_t, child_t)
                        removed[[parent_t, child_t]] = mappings.keys.to_set
                    end
                end
                removed
            end

            def active_task?(t)
                t.plan && !t.finished? && t.execution_agent && !t.execution_agent.finished? && !t.execution_agent.ready_to_die? 
            end

            def update
                tasks = dataflow_graph.modified_tasks
                tasks.delete_if { |t| !active_task?(t) }
                debug "connection: updating, #{tasks.size} tasks modified in dataflow graph"

                # The modifications to +tasks+ might have removed all input
                # connection. Make sure that in this case, executable? has been
                # reset to nil
                #
                # The normal workflow does not work in this case, as it is only
                # looking for tasks whose input connections have been modified
                tasks.each do |t|
                    if t.setup? && !t.executable? && t.plan == plan && t.all_inputs_connected?
                        t.executable = nil
                        scheduler.report_action "all inputs connected, marking as executable", t
                    end
                end

                if !tasks.empty?
                    if dataflow_graph.pending_changes
                        pending_tasks = dataflow_graph.pending_changes.first
                        pending_tasks.delete_if { |t| !active_task?(t) }
                        tasks.merge(pending_tasks)
                    end

                    debug do
                        debug "computing data flow update from modified tasks"
                        for t in tasks
                            debug "  #{t}"
                        end
                        break
                    end

                    new, removed = compute_connection_changes(tasks)
                    if new
                        dataflow_graph.pending_changes = [tasks.dup, new, removed]
                        dataflow_graph.modified_tasks.clear
                    else
                        debug "cannot compute changes, keeping the tasks queued"
                    end
                end

                dangling = dangling_task_cleanup
                if !dangling.empty?
                    dataflow_graph.pending_changes ||= [[], Hash.new, Hash.new]
                    dataflow_graph.pending_changes[2].merge!(dangling) do |k, m0, m1|
                        m0.merge(m1)
                    end
                end

                if dataflow_graph.pending_changes
                    main_tasks, new, removed = dataflow_graph.pending_changes
                    debug "#{main_tasks.size} tasks in pending"
                    main_tasks.delete_if { |t| !active_task?(t) }
                    debug "#{main_tasks.size} tasks after inactive removal"
                    new.delete_if do |(source_task, sink_task), _|
                        !active_task?(source_task) || !active_task?(sink_task)
                    end
                    if removed_connections_require_network_update?(removed)
                        dataflow_graph.pending_changes = [main_tasks, new, removed]
                        Syskit::NetworkGeneration::Engine.resolve(plan)
                        return update
                    end

                    debug "applying pending changes from the data flow graph"
                    new, removed = apply_connection_changes(new, removed)
                    if new.empty? && removed.empty?
                        dataflow_graph.pending_changes = nil
                    else
                        dataflow_graph.pending_changes = [main_tasks, new, removed]
                    end

                    if !dataflow_graph.pending_changes
                        debug "successfully applied pending changes"
                    else
                        debug do
                            debug "some connection changes could not be applied in this pass"
                            main_tasks, new, removed = dataflow_graph.pending_changes
                            additions = new.inject(0) { |count, (_, ports)| count + ports.size }
                            removals  = removed.inject(0) { |count, (_, ports)| count + ports.size }
                            debug "  #{additions} new connections pending"
                            debug "  #{removals} removed connections pending"
                            debug "  involving #{main_tasks.size} tasks"
                            break
                        end
                    end
                end
            end
        end
    end
end

