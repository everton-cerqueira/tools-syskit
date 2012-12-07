require 'syskit'
require 'syskit/test'

class TC_Engine < Test::Unit::TestCase
    include Syskit::SelfTest

    attr_reader :simple_component_model
    attr_reader :simple_task_model
    attr_reader :simple_service_model
    attr_reader :simple_composition_model

    def setup
	super
        plan.engine.scheduler = nil

        srv = @simple_service_model = DataService.new_submodel do
            input_port 'srv_in', '/int'
            output_port 'srv_out', '/int'
        end
        @simple_component_model = TaskContext.new_submodel do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        simple_component_model.provides simple_service_model, :as => 'simple_service',
            'srv_in' => 'in', 'srv_out' => 'out'
        @simple_task_model = TaskContext.new_submodel do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        simple_task_model.provides simple_service_model, :as => 'simple_service',
            'srv_in' => 'in', 'srv_out' => 'out'
        @simple_composition_model = Composition.new_submodel do
            add srv, :as => 'srv'
            export self.srv_child.srv_in_port
            export self.srv_child.srv_out_port
            provides srv, :as => 'srv'
        end
    end

    def test_reconfigure_child_task
        task_model = TaskContext.new_submodel
        composition_model = Composition.new_submodel do
            add task_model, :as => 'child'
        end
        deployment = stub_roby_deployment_model(task_model, 'task')

        plan.add(original = composition_model.as_plan)
        garbage = [original, original.planning_task]
        original = original.as_service
        original.planning_task.start!
        garbage << original.to_task << original.child_child.to_task

        plan.add_mission(new = composition_model.use('child' => task_model.with_conf('non_default')).as_plan)
        garbage << new
        new = new.as_service
        new.planning_task.start!

        assert_equal(['non_default'], new.child_child.conf)
        assert !new.child_child.allow_automatic_setup?
        assert_equal(garbage.to_set, plan.static_garbage_collect.to_set)
        assert new.child_child.allow_automatic_setup?
    end

    def test_reconfigure_toplevel_task
        task_model = TaskContext.new_submodel
        deployment = stub_roby_deployment_model(task_model, 'task')

        orocos_engine.add_mission(task_model)
        orocos_engine.resolve
        original_task = plan.find_tasks(task_model).to_a
        assert_equal(1, original_task.size)
        original_task = original_task.first

        orocos_engine.add_mission(task_model).
            with_conf('non_default')
        orocos_engine.resolve

        tasks = plan.find_tasks(task_model).to_a
        assert_equal(2, tasks.size)
        tasks.delete(original_task)
        new_task = tasks.first

        assert_equal([original_task], plan.static_garbage_collect.to_a)
    end

    def test_resolve_composition_two_times_is_a_noop
        deployment = stub_roby_deployment_model(simple_task_model, 'task')
        # IMPORTANT: using add_mission here makes the task "special", as it is
        # protected from e.g. garbage collection. The test should pass without
        # it
        plan.add(task = simple_composition_model.use('srv' => simple_task_model).as_plan)
        task.planning_task.start!
        assert_equal 5, plan.known_tasks.size
        current_tasks = plan.known_tasks.dup

        plan_copy, mappings = plan.deep_copy

        orocos_engine.resolve
        assert plan.same_plan?(plan_copy, mappings)
    ensure
        plan_copy.clear if plan_copy
    end

    def test_add_permanent_task
        plan.engine.scheduler = nil
        task_model = TaskContext.new_submodel
        deployment = stub_roby_deployment_model(task_model, 'task')
        task = task_model.as_plan
        plan.add_permanent(task)
        srv = task.as_service
        task.planning_task.start!
        orocos_engine.resolve
        assert plan.permanent?(srv.task)
        orocos_engine.resolve
        assert plan.permanent?(srv.task)
    end

    def test_add_mission_task
        plan.engine.scheduler = nil
        task_model = TaskContext.new_submodel
        deployment = stub_roby_deployment_model(task_model, 'task')
        task = task_model.as_plan
        plan.add_mission(task)
        srv = task.as_service
        task.planning_task.start!
        orocos_engine.resolve
        assert plan.mission?(srv.task)
        orocos_engine.resolve
        assert plan.mission?(srv.task)
    end

    def test_reconfigured_deployments_are_sequenced_through_allow_automatic_setup
        stub_roby_deployment_model(simple_task_model, 'task')

        plan.engine.scheduler = nil
        plan.add(cmp = simple_composition_model.use('srv' => simple_task_model).as_plan)
        cmp = cmp.as_service
        cmp.planning_task.start! # resolve the network
        cmp.srv_child.do_not_reuse
        current_child = cmp.srv_child.to_task

        plan.in_transaction do |trsc|
            assert !trsc[cmp.child_from_role('srv')].reusable?
        end

        plan.add(new_cmp = simple_composition_model.use('srv' => simple_task_model).as_plan)
        new_cmp = new_cmp.as_service
        new_cmp.planning_task.start! # resolve the network

        assert_equal cmp.to_task, new_cmp.to_task
        assert !new_cmp.srv_child.allow_automatic_setup?
        plan.remove_object(current_child)
        assert new_cmp.srv_child.allow_automatic_setup?
    end
end


