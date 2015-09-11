module Syskit::GUI
    module ModelViews
        class TaskContext < Component
            attr_reader :orogen_rendering
            attr_reader :task_model_view

            def initialize(page)
                super(page)
                @task_model_view = Roby::GUI::ModelViews::Task.new(page)
                @orogen_rendering = OroGen::HTML::TaskContext.new(page)
                buttons = Array.new
                buttons.concat(self.class.common_graph_buttons('interface'))
                Syskit::Graphviz.available_task_annotations.sort.each do |ann_name|
                    interface_options[:annotations] << ann_name
                end
                interface_options[:buttons] = buttons
            end

            def render(model, external_objects: false)
                doc = [model.doc, model.orogen_model.doc].compact.join("\n\n").strip
                if model.extension_file
                    ComponentNetworkBaseView.html_defined_in(
                        page, model,
                        definition_location: [model.extension_file, 1],
                        with_require: false,
                        format: "<b>Extended in</b> %s")
                else
                    page.push nil, "There is no extension file for this model. You can run <tt>syskit gen orogen #{model.orogen_model.project.name}</tt> to create one, and press the 'Reload Models' button above"
                end
                if !doc.empty?
                    page.push nil, page.main_doc(doc)
                end
                task_model_view.render(model, external_objects: external_objects)
                super

                page.push("oroGen Model", "<p><b>oroGen name:</b> #{model.orogen_model.name}</p>")
                orogen_rendering.render(model.orogen_model, external_objects: external_objects, doc: false)
            end
        end
    end
end

