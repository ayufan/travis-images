require 'shellwords'
require 'docker'
require 'travis/cloud_images/cli/image_creation'

module Travis
  module CloudImages
    class Docker
      class VirtualMachine
        attr_reader :container

        def initialize(container)
          @container = container
        end

        def vm_id
          @id ||= @container.id
        end

        def hostname
          @hostname ||= json['Config']['Hostname']
        end

        def ip_address
          @ip_address ||= json['NetworkSettings']['IPAddress']
        end

        def username
          'travis'
        end

        def state
          if container == nil
            'destroyed'
          elsif json['State']['Running']
            'running'
          elsif json['State']['Paused']
            'paused'
          elsif json['State']['Restarting']
            'restarting'
          elsif json['State']['ExitCode'] == 0
            'finished'
          else
            'error'
          end
        end

        def destroy
          @container.delete(:force => true)
          @container = nil
        end

        private

        def json
          return {} unless @container
          @container.json
        end
      end

      def initialize(default_opts)
      end

      # create a connection
      def connection
        ::Docker.connection
      end

      def servers
        containers = ::Docker::Container.all(:all => true)
        containers = containers.map { |container| VirtualMachine.new(container) }
      end

      def create_server(opts = {})
        name = opts[:hostname]

        image_id = opts[:image_id]
        image_id ||= 'ayufan/travis-base-image:latest'

        container = ::Docker::Container.create('name' => name, 'Hostname' => name, 'Image' => image_id)
        container.start('Privileged' => true)

        vm = VirtualMachine.new(container)

        # VMs are marked as ACTIVE when turned on
        # but they make take awhile to become available via SSH
        retryable(tries: 15, sleep: 6) do
          ::Net::SSH.start(vm.ip_address, 'travis',{ :password => 'travis', :paranoid => false }).shell
        end

        vm
      end

      def save_template(server, desc)
        full_desc = "travis-#{desc}"

        # strip date and hash, it will leave only travis-#dist-#name-#type
        image_type = full_desc.split('-')[1..-7].join('-')

        ::Docker.options[:read_timeout] = 1800
        server.container.commit(
            :repo => 'travis-linux-worker',
            :tag => image_type,
            :comment => full_desc)
        ::Docker.options[:read_timeout] = 60
      end

      def latest_template_matching(regexp)
        travis_templates.
            sort_by { |t| t['created'] }.reverse.
            find { |t| t['description'] =~ Regexp.new(regexp) }
      end

      def latest_template(type)
        latest_template_matching(type)
      end

      def latest_released_template(type)
        latest_template_matching("^travis-#{Regexp.quote(type)}")
      end

      def templates
        ::Docker::Image.all.map do |image|
          tags = image.info['RepoTags']
          description = tags.find { |t| t =~ /^travis-linux-worker:/ }
          next unless description
          description = description.split(':')[-1]
          { 'id' => image.id,
            'created' => image.info['Created'],
            'description' => "travis-#{description}" }
        end.compact
      end

      def travis_templates
        templates.find_all { |t| t['description'] =~ /^travis-/ }
      end

      def find_template(description)
        templates.find { |t| t['description'] == description }
      end

      def clean_up
        servers.each { |server| server.destroy if ['running', 'error'].include?(server.state) }
      end

      def config
        @config ||= {}
      end

      def retryable(opts=nil)
        opts = { :tries => 1, :on => Exception }.merge(opts || {})

        begin
          return yield
        rescue *opts[:on]
          if (opts[:tries] -= 1) > 0
            sleep opts[:sleep].to_f if opts[:sleep]
            retry
          end
          raise
        end
      end
    end
  end
end