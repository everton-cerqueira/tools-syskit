# Load the relevant typekits with import_types_from
# import_types_from 'base'
# You MUST require files that define services that
# you want <%= class_name.last %> to provide
<% indent, open_code, close_code = ::Roby::App::GenBase.in_module(*class_name[0..-2]) %>
<%= open_code %>
<%= indent %>com_bus_type '<%= class_name.last %>', message_type: '/int' do
<%= indent %>    # input_port 'in', '/base/Vector3d'
<%= indent %>    # output_port 'out', '/base/Vector3d'
<%= indent %>    #
<%= indent %>    # Tell syskit that this service provides another. It adds the 
<%= indent %>    # ports from the provided service to this service
<%= indent %>    # provides AnotherSrv
<%= indent %>    #
<%= indent %>    # Tell syskit that this service provides another. It maps ports
<%= indent %>    # from the provided service to the one in this service (instead
<%= indent %>    # of adding)
<%= indent %>    # provides AnotherSrv, 'provided_srv_in' => 'in'

<%= indent %>    ##### Attached Device Configuration Extensions
<%= indent %>    # # When using bus models, it is possible to extend the device
<%= indent %>    # # objects that are attached to the bus with some additional
<%= indent %>    # # configuration capabilities. For instance, with
<%= indent %>    # extend_attached_device_configuration do
<%= indent %>    #     BusID = Struct.new :id, :mask
<%= indent %>    #     # Communication baudrate in bit/s
<%= indent %>    #     dsl_attribute :bus_id do |id, mask|
<%= indent %>    #         # Do some validation of id/mask here
<%= indent %>    #         BusID.new(Integer(id), Integer(mask))
<%= indent %>    #     end
<%= indent %>    # end
<%= indent %>    # # One can do the following in the robot description:
<%= indent %>    # # robot do
<%= indent %>    # #     com_bus <%= class_name.last %>, as: 'bus' do
<%= indent %>    # #         device(<%= class_name.last %>SpecificDevice, as: 'dev').
<%= indent %>    # #             bus_id(0x1, 0xF)
<%= indent %>    # #     end
<%= indent %>    # # end
<%= indent %>    # # 
<%= indent %>    # # and then use the information to auto-configure the bus driver
<%= indent %>    # # class OroGen::MyBusDeviceDriver::Task
<%= indent %>    # #     driver_for <%= class_name.last %>, as: 'driver'
<%= indent %>    # #     def configure
<%= indent %>    # #         super
<%= indent %>    # #         
<%= indent %>    # #         # Set the bus driver's 'watches' property to the declared devices
<%= indent %>    # #         orocos_task.watches = each_declared_attached_device.map do |dev|
<%= indent %>    # #             bus_id = Types.my_bus_device_driver.BusID.new
<%= indent %>    # #             bus_id.name = dev.name
<%= indent %>    # #             bus_id.id = dev.bus_id.id
<%= indent %>    # #             bus_id.mask = dev.bus_id.mask
<%= indent %>    # #             bus_id
<%= indent %>    # #         end
<%= indent %>    # #     end
<%= indent %>    # # end
<%= indent %>    # #
<%= indent %>    # # NOTE: this should be limited to device-specific configurations
<%= indent %>    # # NOTE: driver-specific parameters must be set in the corresponding
<%= indent %>    # # NOTE: oroGen configuration file

<%= indent %>    ##### Device Configuration Extensions
<%= indent %>    # # Bus models are first device models. They can therefore
<%= indent %>    # # define configuration extensions, which extend the
<%= indent %>    # # configuration capabilities of the device. For instance, with
<%= indent %>    # extend_device_configuration do
<%= indent %>    #     # Communication baudrate in bit/s
<%= indent %>    #     dsl_attribute :baudrate do |value|
<%= indent %>    #         Float(value)
<%= indent %>    #     end
<%= indent %>    # end
<%= indent %>    # # One can do the following in the robot description:
<%= indent %>    # # robot do
<%= indent %>    # #     device(<%= class_name.last %>).
<%= indent %>    # #         baudrate(1_000_000) # Use 1Mbit/s
<%= indent %>    # # end
<%= indent %>    # # 
<%= indent %>    # # and then use the information to auto-configure the device
<%= indent %>    # # drivers
<%= indent %>    # # class OroGen::MyDeviceDriver::Task
<%= indent %>    # #     driver_for <%= class_name.last %>, as: 'driver'
<%= indent %>    # #     def configure
<%= indent %>    # #         super
<%= indent %>    # #         orocos_task.baudrate = robot_device.baudrate
<%= indent %>    # #     end
<%= indent %>    # # end
<%= indent %>    # #
<%= indent %>    # # NOTE: this should be limited to device-specific configurations
<%= indent %>    # # NOTE: driver-specific parameters must be set in the corresponding
<%= indent %>    # # NOTE: oroGen configuration file

<%= indent %>end
<%= close_code %>
