module Vmpooler
  class PoolManager
    class Provider
      class VSphere < Vmpooler::PoolManager::Provider::Base
        # The connection_pool method is normally used only for testing
        attr_reader :connection_pool

        def initialize(config, logger, metrics, name, options)
          super(config, logger, metrics, name, options)

          task_limit = global_config[:config].nil? || global_config[:config]['task_limit'].nil? ? 10 : global_config[:config]['task_limit'].to_i
          # The default connection pool size is:
          # Whatever is biggest from:
          #   - How many pools this provider services
          #   - Maximum number of cloning tasks allowed
          #   - Need at least 2 connections so that a pool can have inventory functions performed while cloning etc.
          default_connpool_size = [provided_pools.count, task_limit, 2].max
          connpool_size = provider_config['connection_pool_size'].nil? ? default_connpool_size : provider_config['connection_pool_size'].to_i
          # The default connection pool timeout should be quite large - 60 seconds
          connpool_timeout = provider_config['connection_pool_timeout'].nil? ? 60 : provider_config['connection_pool_timeout'].to_i
          logger.log('d', "[#{name}] ConnPool - Creating a connection pool of size #{connpool_size} with timeout #{connpool_timeout}")
          @connection_pool = Vmpooler::PoolManager::GenericConnectionPool.new(
            metrics: metrics,
            metric_prefix: "#{name}_provider_connection_pool",
            size: connpool_size,
            timeout: connpool_timeout
          ) do
            logger.log('d', "[#{name}] Connection Pool - Creating a connection object")
            # Need to wrap the vSphere connection object in another object. The generic connection pooler will preserve
            # the object reference for the connection, which means it cannot "reconnect" by creating an entirely new connection
            # object.  Instead by wrapping it in a Hash, the Hash object reference itself never changes but the content of the
            # Hash can change, and is preserved across invocations.
            new_conn = connect_to_vsphere
            { connection: new_conn }
          end
        end

        # name of the provider class
        def name
          'vsphere'
        end

        def vms_in_pool(pool_name)
          vms = []
          @connection_pool.with_metrics do |pool_object|
            connection = ensured_vsphere_connection(pool_object)
            foldername = pool_config(pool_name)['folder']
            folder_object = find_folder(foldername, connection)

            return vms if folder_object.nil?

            folder_object.childEntity.each do |vm|
              vms << { 'name' => vm.name }
            end
          end
          vms
        end

        def get_vm_host(_pool_name, vm_name)
          host_name = nil

          @connection_pool.with_metrics do |pool_object|
            connection = ensured_vsphere_connection(pool_object)
            vm_object = find_vm(vm_name, connection)
            return host_name if vm_object.nil?

            host_name = vm_object.summary.runtime.host.name if vm_object.summary && vm_object.summary.runtime && vm_object.summary.runtime.host
          end
          host_name
        end

        def find_least_used_compatible_host(_pool_name, vm_name)
          hostname = nil
          @connection_pool.with_metrics do |pool_object|
            connection = ensured_vsphere_connection(pool_object)
            vm_object = find_vm(vm_name, connection)

            return hostname if vm_object.nil?
            host_object = find_least_used_vpshere_compatible_host(vm_object)

            return hostname if host_object.nil?
            hostname = host_object[0].name
          end
          hostname
        end

        def migrate_vm_to_host(pool_name, vm_name, dest_host_name)
          pool = pool_config(pool_name)
          raise("Pool #{pool_name} does not exist for the provider #{name}") if pool.nil?

          @connection_pool.with_metrics do |pool_object|
            connection = ensured_vsphere_connection(pool_object)
            vm_object = find_vm(vm_name, connection)
            raise("VM #{vm_name} does not exist in Pool #{pool_name} for the provider #{name}") if vm_object.nil?

            target_cluster_name = get_target_cluster_from_config(pool_name)
            cluster = find_cluster(target_cluster_name, connection)
            raise("Pool #{pool_name} specifies cluster #{target_cluster_name} which does not exist for the provider #{name}") if cluster.nil?

            # Go through each host and initiate a migration when the correct host name is found
            cluster.host.each do |host|
              if host.name == dest_host_name
                migrate_vm_host(vm_object, host)
                return true
              end
            end
          end
          false
        end

        def get_vm(_pool_name, vm_name)
          vm_hash = nil
          @connection_pool.with_metrics do |pool_object|
            connection = ensured_vsphere_connection(pool_object)
            vm_object = find_vm(vm_name, connection)
            return vm_hash if vm_object.nil?

            vm_folder_path = get_vm_folder_path(vm_object)
            # Find the pool name based on the folder path
            pool_name = nil
            template_name = nil
            global_config[:pools].each do |pool|
              if pool['folder'] == vm_folder_path
                pool_name = pool['name']
                template_name = pool['template']
              end
            end

            vm_hash = generate_vm_hash(vm_object, template_name, pool_name)
          end
          vm_hash
        end

        def create_vm(pool_name, new_vmname)
          pool = pool_config(pool_name)
          raise("Pool #{pool_name} does not exist for the provider #{name}") if pool.nil?
          vm_hash = nil
          @connection_pool.with_metrics do |pool_object|
            connection = ensured_vsphere_connection(pool_object)
            # Assume all pool config is valid i.e. not missing
            template_path = pool['template']
            target_folder_path = pool['folder']
            target_datastore = pool['datastore']
            target_cluster_name = get_target_cluster_from_config(pool_name)

            # Extract the template VM name from the full path
            raise("Pool #{pool_name} did specify a full path for the template for the provider #{name}") unless template_path =~ /\//
            templatefolders = template_path.split('/')
            template_name = templatefolders.pop

            # Get the actual objects from vSphere
            template_folder_object = find_folder(templatefolders.join('/'), connection)
            raise("Pool #{pool_name} specifies a template folder of #{templatefolders.join('/')} which does not exist for the provider #{name}") if template_folder_object.nil?

            template_vm_object = template_folder_object.find(template_name)
            raise("Pool #{pool_name} specifies a template VM of #{template_name} which does not exist for the provider #{name}") if template_vm_object.nil?

            # Annotate with creation time, origin template, etc.
            # Add extraconfig options that can be queried by vmtools
            config_spec = RbVmomi::VIM.VirtualMachineConfigSpec(
              annotation: JSON.pretty_generate(
                name: new_vmname,
                created_by: provider_config['username'],
                base_template: template_path,
                creation_timestamp: Time.now.utc
              ),
              extraConfig: [
                { key: 'guestinfo.hostname', value: new_vmname }
              ]
            )

            # Choose a cluster/host to place the new VM on
            target_host_object = find_least_used_host(target_cluster_name, connection)

            # Put the VM in the specified folder and resource pool
            relocate_spec = RbVmomi::VIM.VirtualMachineRelocateSpec(
              datastore: find_datastore(target_datastore, connection),
              host: target_host_object,
              diskMoveType: :moveChildMostDiskBacking
            )

            # Create a clone spec
            clone_spec = RbVmomi::VIM.VirtualMachineCloneSpec(
              location: relocate_spec,
              config: config_spec,
              powerOn: true,
              template: false
            )

            # Create the new VM
            new_vm_object = template_vm_object.CloneVM_Task(
              folder: find_folder(target_folder_path, connection),
              name: new_vmname,
              spec: clone_spec
            ).wait_for_completion

            vm_hash = generate_vm_hash(new_vm_object, template_path, pool_name)
          end
          vm_hash
        end

        def create_disk(pool_name, vm_name, disk_size)
          pool = pool_config(pool_name)
          raise("Pool #{pool_name} does not exist for the provider #{name}") if pool.nil?

          datastore_name = pool['datastore']
          raise("Pool #{pool_name} does not have a datastore defined for the provider #{name}") if datastore_name.nil?

          @connection_pool.with_metrics do |pool_object|
            connection = ensured_vsphere_connection(pool_object)
            vm_object = find_vm(vm_name, connection)
            raise("VM #{vm_name} in pool #{pool_name} does not exist for the provider #{name}") if vm_object.nil?

            add_disk(vm_object, disk_size, datastore_name, connection)
          end
          true
        end

        def create_snapshot(pool_name, vm_name, new_snapshot_name)
          @connection_pool.with_metrics do |pool_object|
            connection = ensured_vsphere_connection(pool_object)
            vm_object = find_vm(vm_name, connection)
            raise("VM #{vm_name} in pool #{pool_name} does not exist for the provider #{name}") if vm_object.nil?

            old_snap = find_snapshot(vm_object, new_snapshot_name)
            raise("Snapshot #{new_snapshot_name} for VM #{vm_name} in pool #{pool_name} already exists for the provider #{name}") unless old_snap.nil?

            vm_object.CreateSnapshot_Task(
              name: new_snapshot_name,
              description: 'vmpooler',
              memory: true,
              quiesce: true
            ).wait_for_completion
          end
          true
        end

        def revert_snapshot(pool_name, vm_name, snapshot_name)
          @connection_pool.with_metrics do |pool_object|
            connection = ensured_vsphere_connection(pool_object)
            vm_object = find_vm(vm_name, connection)
            raise("VM #{vm_name} in pool #{pool_name} does not exist for the provider #{name}") if vm_object.nil?

            snapshot_object = find_snapshot(vm_object, snapshot_name)
            raise("Snapshot #{snapshot_name} for VM #{vm_name} in pool #{pool_name} does not exist for the provider #{name}") if snapshot_object.nil?

            snapshot_object.RevertToSnapshot_Task.wait_for_completion
          end
          true
        end

        def destroy_vm(_pool_name, vm_name)
          @connection_pool.with_metrics do |pool_object|
            connection = ensured_vsphere_connection(pool_object)
            vm_object = find_vm(vm_name, connection)
            # If a VM doesn't exist then it is effectively deleted
            return true if vm_object.nil?

            # Poweroff the VM if it's running
            vm_object.PowerOffVM_Task.wait_for_completion if vm_object.runtime && vm_object.runtime.powerState && vm_object.runtime.powerState == 'poweredOn'

            # Kill it with fire
            vm_object.Destroy_Task.wait_for_completion
          end
          true
        end

        def vm_ready?(_pool_name, vm_name)
          begin
            open_socket(vm_name)
          rescue => _err
            return false
          end

          true
        end

        # VSphere Helper methods

        def get_target_cluster_from_config(pool_name)
          pool = pool_config(pool_name)
          return nil if pool.nil?

          return pool['clone_target'] unless pool['clone_target'].nil?
          return global_config[:config]['clone_target'] unless global_config[:config]['clone_target'].nil?

          nil
        end

        def generate_vm_hash(vm_object, template_name, pool_name)
          hash = { 'name' => nil, 'hostname' => nil, 'template' => nil, 'poolname' => nil, 'boottime' => nil, 'powerstate' => nil }

          hash['name']     = vm_object.name
          hash['hostname'] = vm_object.summary.guest.hostName if vm_object.summary && vm_object.summary.guest && vm_object.summary.guest.hostName
          hash['template'] = template_name
          hash['poolname'] = pool_name
          hash['boottime']   = vm_object.runtime.bootTime if vm_object.runtime && vm_object.runtime.bootTime
          hash['powerstate'] = vm_object.runtime.powerState if vm_object.runtime && vm_object.runtime.powerState

          hash
        end

        # vSphere helper methods
        ADAPTER_TYPE = 'lsiLogic'.freeze
        DISK_TYPE = 'thin'.freeze
        DISK_MODE = 'persistent'.freeze

        def ensured_vsphere_connection(connection_pool_object)
          connection_pool_object[:connection] = connect_to_vsphere unless vsphere_connection_ok?(connection_pool_object[:connection])
          connection_pool_object[:connection]
        end

        def vsphere_connection_ok?(connection)
          _result = connection.serviceInstance.CurrentTime
          return true
        rescue
          return false
        end

        def connect_to_vsphere
          max_tries = global_config[:config]['max_tries'] || 3
          retry_factor = global_config[:config]['retry_factor'] || 10
          try = 1
          begin
            connection = RbVmomi::VIM.connect host: provider_config['server'],
                                              user: provider_config['username'],
                                              password: provider_config['password'],
                                              insecure: provider_config['insecure'] || true
            metrics.increment('connect.open')
            return connection
          rescue => err
            try += 1
            metrics.increment('connect.fail')
            raise err if try == max_tries
            sleep(try * retry_factor)
            retry
          end
        end

        # This should supercede the open_socket method in the Pool Manager
        def open_socket(host, domain = nil, timeout = 5, port = 22, &_block)
          Timeout.timeout(timeout) do
            target_host = host
            target_host = "#{host}.#{domain}" if domain
            sock = TCPSocket.new target_host, port
            begin
              yield sock if block_given?
            ensure
              sock.close
            end
          end
        end

        def get_vm_folder_path(vm_object)
          # This gives an array starting from the root Datacenters folder all the way to the VM
          # [ [Object, String], [Object, String ] ... ]
          # It's then reversed so that it now goes from the VM to the Datacenter
          full_path = vm_object.path.reverse

          # Find the Datacenter object
          dc_index = full_path.index { |p| p[0].is_a?(RbVmomi::VIM::Datacenter) }
          return nil if dc_index.nil?
          # The Datacenter should be at least 2 otherwise there's something
          # wrong with the array passed in
          # This is the minimum:
          # [ VM (0), VM ROOT FOLDER (1), DC (2)]
          return nil if dc_index <= 1

          # Remove the VM name (Starting position of 1 in the slice)
          # Up until the Root VM Folder of DataCenter Node (dc_index - 2)
          full_path = full_path.slice(1..dc_index - 2)

          # Reverse the array back to normal and
          # then convert the array of paths into a '/' seperated string
          (full_path.reverse.map { |p| p[1] }).join('/')
        end

        def add_disk(vm, size, datastore, connection)
          return false unless size.to_i > 0

          vmdk_datastore = find_datastore(datastore, connection)
          vmdk_file_name = "#{vm['name']}/#{vm['name']}_#{find_vmdks(vm['name'], datastore, connection).length + 1}.vmdk"

          controller = find_disk_controller(vm)

          vmdk_spec = RbVmomi::VIM::FileBackedVirtualDiskSpec(
            capacityKb: size.to_i * 1024 * 1024,
            adapterType: ADAPTER_TYPE,
            diskType: DISK_TYPE
          )

          vmdk_backing = RbVmomi::VIM::VirtualDiskFlatVer2BackingInfo(
            datastore: vmdk_datastore,
            diskMode: DISK_MODE,
            fileName: "[#{vmdk_datastore.name}] #{vmdk_file_name}"
          )

          device = RbVmomi::VIM::VirtualDisk(
            backing: vmdk_backing,
            capacityInKB: size.to_i * 1024 * 1024,
            controllerKey: controller.key,
            key: -1,
            unitNumber: find_disk_unit_number(vm, controller)
          )

          device_config_spec = RbVmomi::VIM::VirtualDeviceConfigSpec(
            device: device,
            operation: RbVmomi::VIM::VirtualDeviceConfigSpecOperation('add')
          )

          vm_config_spec = RbVmomi::VIM::VirtualMachineConfigSpec(
            deviceChange: [device_config_spec]
          )

          connection.serviceContent.virtualDiskManager.CreateVirtualDisk_Task(
            datacenter: connection.serviceInstance.find_datacenter,
            name: "[#{vmdk_datastore.name}] #{vmdk_file_name}",
            spec: vmdk_spec
          ).wait_for_completion

          vm.ReconfigVM_Task(spec: vm_config_spec).wait_for_completion

          true
        end

        def find_datastore(datastorename, connection)
          datacenter = connection.serviceInstance.find_datacenter
          datacenter.find_datastore(datastorename)
        end

        def find_device(vm, device_name)
          vm.config.hardware.device.each do |device|
            return device if device.deviceInfo.label == device_name
          end

          nil
        end

        def find_disk_controller(vm)
          devices = find_disk_devices(vm)

          devices.keys.sort.each do |device|
            if devices[device]['children'].length < 15
              return find_device(vm, devices[device]['device'].deviceInfo.label)
            end
          end

          nil
        end

        def find_disk_devices(vm)
          devices = {}

          vm.config.hardware.device.each do |device|
            if device.is_a? RbVmomi::VIM::VirtualSCSIController
              if devices[device.controllerKey].nil?
                devices[device.key] = {}
                devices[device.key]['children'] = []
              end

              devices[device.key]['device'] = device
            end

            if device.is_a? RbVmomi::VIM::VirtualDisk
              if devices[device.controllerKey].nil?
                devices[device.controllerKey] = {}
                devices[device.controllerKey]['children'] = []
              end

              devices[device.controllerKey]['children'].push(device)
            end
          end

          devices
        end

        def find_disk_unit_number(vm, controller)
          used_unit_numbers = []
          available_unit_numbers = []

          devices = find_disk_devices(vm)

          devices.keys.sort.each do |c|
            next unless controller.key == devices[c]['device'].key
            used_unit_numbers.push(devices[c]['device'].scsiCtlrUnitNumber)
            devices[c]['children'].each do |disk|
              used_unit_numbers.push(disk.unitNumber)
            end
          end

          (0..15).each do |scsi_id|
            if used_unit_numbers.grep(scsi_id).length <= 0
              available_unit_numbers.push(scsi_id)
            end
          end

          available_unit_numbers.sort[0]
        end

        def find_folder(foldername, connection)
          datacenter = connection.serviceInstance.find_datacenter
          base = datacenter.vmFolder

          folders = foldername.split('/')
          folders.each do |folder|
            raise("Unexpected object type encountered (#{base.class}) while finding folder") unless base.is_a? RbVmomi::VIM::Folder
            base = base.childEntity.find { |f| f.name == folder }
          end

          base
        end

        # Returns an array containing cumulative CPU and memory utilization of a host, and its object reference
        # Params:
        # +model+:: CPU arch version to match on
        # +limit+:: Hard limit for CPU or memory utilization beyond which a host is excluded for deployments
        def get_host_utilization(host, model = nil, limit = 90)
          if model
            return nil unless host_has_cpu_model?(host, model)
          end
          return nil if host.runtime.inMaintenanceMode
          return nil unless host.overallStatus == 'green'

          cpu_utilization = cpu_utilization_for host
          memory_utilization = memory_utilization_for host

          return nil if cpu_utilization > limit
          return nil if memory_utilization > limit

          [cpu_utilization + memory_utilization, host]
        end

        def host_has_cpu_model?(host, model)
          get_host_cpu_arch_version(host) == model
        end

        def get_host_cpu_arch_version(host)
          cpu_model = host.hardware.cpuPkg[0].description
          cpu_model_parts = cpu_model.split
          arch_version = cpu_model_parts[4]
          arch_version
        end

        def cpu_utilization_for(host)
          cpu_usage = host.summary.quickStats.overallCpuUsage
          cpu_size = host.summary.hardware.cpuMhz * host.summary.hardware.numCpuCores
          (cpu_usage.to_f / cpu_size.to_f) * 100
        end

        def memory_utilization_for(host)
          memory_usage = host.summary.quickStats.overallMemoryUsage
          memory_size = host.summary.hardware.memorySize / 1024 / 1024
          (memory_usage.to_f / memory_size.to_f) * 100
        end

        def find_least_used_host(cluster, connection)
          cluster_object = find_cluster(cluster, connection)
          target_hosts = get_cluster_host_utilization(cluster_object)
          least_used_host = target_hosts.sort[0][1]
          least_used_host
        end

        def find_cluster(cluster, connection)
          datacenter = connection.serviceInstance.find_datacenter
          datacenter.hostFolder.children.find { |cluster_object| cluster_object.name == cluster }
        end

        def get_cluster_host_utilization(cluster)
          cluster_hosts = []
          cluster.host.each do |host|
            host_usage = get_host_utilization(host)
            cluster_hosts << host_usage if host_usage
          end
          cluster_hosts
        end

        def find_least_used_vpshere_compatible_host(vm)
          source_host = vm.summary.runtime.host
          model = get_host_cpu_arch_version(source_host)
          cluster = source_host.parent
          target_hosts = []
          cluster.host.each do |host|
            host_usage = get_host_utilization(host, model)
            target_hosts << host_usage if host_usage
          end
          target_host = target_hosts.sort[0][1]
          [target_host, target_host.name]
        end

        def find_pool(poolname, connection)
          datacenter = connection.serviceInstance.find_datacenter
          base = datacenter.hostFolder
          pools = poolname.split('/')
          pools.each do |pool|
            if base.is_a?(RbVmomi::VIM::Folder)
              base = base.childEntity.find { |f| f.name == pool }
            elsif base.is_a?(RbVmomi::VIM::ClusterComputeResource)
              base = base.resourcePool.resourcePool.find { |f| f.name == pool }
            elsif base.is_a?(RbVmomi::VIM::ResourcePool)
              base = base.resourcePool.find { |f| f.name == pool }
            else
              raise("Unexpected object type encountered (#{base.class}) while finding resource pool")
            end
          end

          base = base.resourcePool unless base.is_a?(RbVmomi::VIM::ResourcePool) && base.respond_to?(:resourcePool)
          base
        end

        def find_snapshot(vm, snapshotname)
          get_snapshot_list(vm.snapshot.rootSnapshotList, snapshotname) if vm.snapshot
        end

        def find_vm(vmname, connection)
          find_vm_light(vmname, connection) || find_vm_heavy(vmname, connection)[vmname]
        end

        def find_vm_light(vmname, connection)
          connection.searchIndex.FindByDnsName(vmSearch: true, dnsName: vmname)
        end

        def find_vm_heavy(vmname, connection)
          vmname = vmname.is_a?(Array) ? vmname : [vmname]
          container_view = get_base_vm_container_from(connection)
          property_collector = connection.propertyCollector

          object_set = [{
            obj: container_view,
            skip: true,
            selectSet: [RbVmomi::VIM::TraversalSpec.new(
              name: 'gettingTheVMs',
              path: 'view',
              skip: false,
              type: 'ContainerView'
            )]
          }]

          prop_set = [{
            pathSet: ['name'],
            type: 'VirtualMachine'
          }]

          results = property_collector.RetrievePropertiesEx(
            specSet: [{
              objectSet: object_set,
              propSet: prop_set
            }],
            options: { maxObjects: nil }
          )

          vms = {}
          results.objects.each do |result|
            name = result.propSet.first.val
            next unless vmname.include? name
            vms[name] = result.obj
          end

          while results.token
            results = property_collector.ContinueRetrievePropertiesEx(token: results.token)
            results.objects.each do |result|
              name = result.propSet.first.val
              next unless vmname.include? name
              vms[name] = result.obj
            end
          end

          vms
        end

        def find_vmdks(vmname, datastore, connection)
          disks = []

          vmdk_datastore = find_datastore(datastore, connection)

          vm_files = vmdk_datastore._connection.serviceContent.propertyCollector.collectMultiple vmdk_datastore.vm, 'layoutEx.file'
          vm_files.keys.each do |f|
            vm_files[f]['layoutEx.file'].each do |l|
              if l.name =~ /^\[#{vmdk_datastore.name}\] #{vmname}\/#{vmname}_([0-9]+).vmdk/
                disks.push(l)
              end
            end
          end

          disks
        end

        def get_base_vm_container_from(connection)
          view_manager = connection.serviceContent.viewManager
          view_manager.CreateContainerView(
            container: connection.serviceContent.rootFolder,
            recursive: true,
            type: ['VirtualMachine']
          )
        end

        def get_snapshot_list(tree, snapshotname)
          snapshot = nil

          tree.each do |child|
            if child.name == snapshotname
              snapshot ||= child.snapshot
            else
              snapshot ||= get_snapshot_list(child.childSnapshotList, snapshotname)
            end
          end

          snapshot
        end

        def migrate_vm_host(vm, host)
          relospec = RbVmomi::VIM.VirtualMachineRelocateSpec(host: host)
          vm.RelocateVM_Task(spec: relospec).wait_for_completion
        end
      end
    end
  end
end
