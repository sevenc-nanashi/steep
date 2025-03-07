module Steep
  module Server
    class Master
      LSP = LanguageServer::Protocol

      class TypeCheckRequest
        attr_reader :guid
        attr_reader :library_paths
        attr_reader :signature_paths
        attr_reader :code_paths
        attr_reader :priority_paths
        attr_reader :checked_paths

        def initialize(guid:)
          @guid = guid
          @library_paths = Set[]
          @signature_paths = Set[]
          @code_paths = Set[]
          @priority_paths = Set[]
          @checked_paths = Set[]
        end

        def uri(path)
          URI.parse(path.to_s).tap do |uri|
            uri.scheme = "file"
          end
        end

        def as_json(assignment:)
          {
            guid: guid,
            library_uris: library_paths.grep(assignment).map {|path| uri(path).to_s },
            signature_uris: signature_paths.grep(assignment).map {|path| uri(path).to_s },
            code_uris: code_paths.grep(assignment).map {|path| uri(path).to_s },
            priority_uris: priority_paths.map {|path| uri(path).to_s }
          }
        end

        def total
          library_paths.size + signature_paths.size + code_paths.size
        end

        def percentage
          checked_paths.size * 100 / total
        end

        def all_paths
          library_paths + signature_paths + code_paths
        end

        def checking_path?(path)
          library_paths.include?(path) ||
            signature_paths.include?(path) ||
            code_paths.include?(path)
        end

        def checked(path)
          raise unless checking_path?(path)
          checked_paths << path
        end

        def finished?
          unchecked_paths.empty?
        end

        def unchecked_paths
          all_paths - checked_paths
        end

        def unchecked_code_paths
          code_paths - checked_paths
        end

        def unchecked_library_paths
          library_paths - checked_paths
        end

        def unchecked_signature_paths
          signature_paths - checked_paths
        end
      end

      class TypeCheckController
        attr_reader :project
        attr_reader :priority_paths
        attr_reader :changed_paths
        attr_reader :target_paths

        class TargetPaths
          attr_reader :project
          attr_reader :target
          attr_reader :code_paths
          attr_reader :signature_paths
          attr_reader :library_paths

          def initialize(project:, target:)
            @project = project
            @target = target
            @code_paths = Set[]
            @signature_paths = Set[]
            @library_paths = Set[]
          end

          def all_paths
            code_paths + signature_paths + library_paths
          end

          def library_path?(path)
            library_paths.include?(path)
          end

          def signature_path?(path)
            signature_paths.include?(path)
          end

          def code_path?(path)
            code_paths.include?(path)
          end

          def add(path)
            return if library_path?(path) || signature_path?(path) || code_path?(path)

            relative_path = project.relative_path(path)

            case
            when target.source_pattern =~ relative_path
              code_paths << path
            when target.signature_pattern =~ relative_path
              signature_paths << path
            else
              library_paths << path
            end
          end

          alias << add
        end

        def initialize(project:)
          @project = project
          @priority_paths = Set[]
          @changed_paths = Set[]
          @target_paths = project.targets.each.map {|target| TargetPaths.new(project: project, target: target) }
        end

        def load(command_line_args:)
          loader = Services::FileLoader.new(base_dir: project.base_dir)

          target_paths.each do |paths|
            target = paths.target

            signature_service = Services::SignatureService.load_from(target.new_env_loader(project: project))
            paths.library_paths.merge(signature_service.env_rbs_paths)

            loader.each_path_in_patterns(target.source_pattern, command_line_args) do |path|
              paths.code_paths << project.absolute_path(path)
            end
            loader.each_path_in_patterns(target.signature_pattern) do |path|
              paths.signature_paths << project.absolute_path(path)
            end

            changed_paths.merge(paths.all_paths)
          end
        end

        def push_changes(path)
          return if target_paths.any? {|paths| paths.library_path?(path) }

          target_paths.each {|paths| paths << path }

          if target_paths.any? {|paths| paths.code_path?(path) || paths.signature_path?(path) }
            changed_paths << path
          end
        end

        def update_priority(open: nil, close: nil)
          path = open || close

          target_paths.each {|paths| paths << path }

          case
          when open
            priority_paths << path
          when close
            priority_paths.delete path
          end
        end

        def make_request(guid: SecureRandom.uuid, last_request: nil, include_unchanged: false)
          return if changed_paths.empty? && !include_unchanged

          TypeCheckRequest.new(guid: guid).tap do |request|
            if last_request
              request.library_paths.merge(last_request.unchecked_library_paths)
              request.signature_paths.merge(last_request.unchecked_signature_paths)
              request.code_paths.merge(last_request.unchecked_code_paths)
            end

            if include_unchanged
              target_paths.each do |paths|
                request.signature_paths.merge(paths.signature_paths)
                request.library_paths.merge(paths.library_paths)
                request.code_paths.merge(paths.code_paths)
              end
            else
              updated_paths = target_paths.select {|paths| changed_paths.intersect?(paths.all_paths) }

              updated_paths.each do |paths|
                case
                when paths.signature_paths.intersect?(changed_paths)
                  request.signature_paths.merge(paths.signature_paths)
                  request.library_paths.merge(paths.library_paths)
                  request.code_paths.merge(paths.code_paths)
                when paths.code_paths.intersect?(changed_paths)
                  request.code_paths.merge(paths.code_paths & changed_paths)
                end
              end
            end

            request.priority_paths.merge(priority_paths)

            changed_paths.clear()
          end
        end
      end

      class ResultHandler
        attr_reader :request
        attr_reader :completion_handler
        attr_reader :response

        def initialize(request:)
          @request = request
          @response = nil
          @completion_handler = nil
          @completed = false
        end

        def process_response(message)
          if request[:id] == message[:id]
            completion_handler&.call(message)
            @response = message
            true
          else
            false
          end
        end

        def result
          response&.dig(:result)
        end

        def completed?
          !!@response
        end

        def on_completion(&block)
          @completion_handler = block
        end
      end

      class GroupHandler
        attr_reader :request
        attr_reader :handlers
        attr_reader :completion_handler

        def initialize()
          @handlers = {}
          @waiting_handlers = Set[]
          @completion_handler = nil
        end

        def process_response(message)
          if handler = handlers[message[:id]]
            handler.process_response(message)

            if completed?
              completion_handler&.call(handlers.values)
            end

            true
          else
            false
          end
        end

        def completed?
          handlers.each_value.all? {|handler| handler.completed? }
        end

        def <<(handler)
          handlers[handler.request[:id]] = handler
        end

        def on_completion(&block)
          @completion_handler = block
        end
      end

      class ResultController
        attr_reader :handlers

        def initialize()
          @handlers = []
        end

        def <<(handler)
          @handlers << handler
        end

        def request_group()
          group = GroupHandler.new()
          yield group
          group
        end

        def process_response(message)
          handlers.each do |handler|
            return true if handler.process_response(message)
          end
          false
        ensure
          handlers.reject!(&:completed?)
        end
      end

      ReceiveMessageJob = Struct.new(:source, :message, keyword_init: true) do
        def response?
          message.key?(:id) && !message.key?(:method)
        end
      end

      SendMessageJob = Struct.new(:dest, :message, keyword_init: true) do
        def self.to_worker(worker, message:)
          new(dest: worker, message: message)
        end

        def self.to_client(message:)
          new(dest: :client, message: message)
        end
      end

      attr_reader :steepfile
      attr_reader :project
      attr_reader :reader, :writer
      attr_reader :commandline_args

      attr_reader :interaction_worker
      attr_reader :typecheck_workers

      attr_reader :job_queue

      attr_reader :current_type_check_request
      attr_reader :controller
      attr_reader :result_controller

      attr_reader :initialize_params
      attr_accessor :typecheck_automatically

      def initialize(project:, reader:, writer:, interaction_worker:, typecheck_workers:, queue: Queue.new)
        @project = project
        @reader = reader
        @writer = writer
        @interaction_worker = interaction_worker
        @typecheck_workers = typecheck_workers
        @current_type_check_request = nil
        @typecheck_automatically = true
        @commandline_args = []
        @job_queue = queue

        @controller = TypeCheckController.new(project: project)
        @result_controller = ResultController.new()
      end

      def start
        Steep.logger.tagged "master" do
          tags = Steep.logger.formatter.current_tags.dup

          worker_threads = []

          if interaction_worker
            worker_threads << Thread.new do
              Steep.logger.formatter.push_tags(*tags, "from-worker@interaction")
              interaction_worker.reader.read do |message|
                job_queue << ReceiveMessageJob.new(source: interaction_worker, message: message)
              end
            end
          end

          typecheck_workers.each do |worker|
            worker_threads << Thread.new do
              Steep.logger.formatter.push_tags(*tags, "from-worker@#{worker.name}")
              worker.reader.read do |message|
                job_queue << ReceiveMessageJob.new(source: worker, message: message)
              end
            end
          end

          read_client_thread = Thread.new do
            reader.read do |message|
              job_queue << ReceiveMessageJob.new(source: :client, message: message)
              break if message[:method] == "exit"
            end
          end

          Steep.logger.tagged "main" do
            while job = job_queue.deq
              case job
              when ReceiveMessageJob
                src = if job.source == :client
                        :client
                      else
                        job.source.name
                      end
                Steep.logger.tagged("ReceiveMessageJob(#{src}/#{job.message[:method]}/#{job.message[:id]})") do
                  if job.response? && result_controller.process_response(job.message)
                    # nop
                    Steep.logger.info { "Processed by ResultController" }
                  else
                    case job.source
                    when :client
                      process_message_from_client(job.message)

                      if job.message[:method] == "exit"
                        job_queue.close()
                      end
                    when WorkerProcess
                      process_message_from_worker(job.message, worker: job.source)
                    end
                  end
                end
              when SendMessageJob
                case job.dest
                when :client
                  Steep.logger.info { "Processing SendMessageJob: dest=client, method=#{job.message[:method] || "-"}, id=#{job.message[:id] || "-"}" }
                  writer.write job.message
                when WorkerProcess
                  Steep.logger.info { "Processing SendMessageJob: dest=#{job.dest.name}, method=#{job.message[:method] || "-"}, id=#{job.message[:id] || "-"}" }
                  job.dest << job.message
                end
              end
            end

            read_client_thread.join()
            worker_threads.each do |thread|
              thread.join
            end
          end
        end
      end

      def each_worker(&block)
        if block_given?
          yield interaction_worker if interaction_worker
          typecheck_workers.each &block
        else
          enum_for :each_worker
        end
      end

      def pathname(uri)
        Pathname(URI.parse(uri).path)
      end

      def work_done_progress_supported?
        initialize_params&.dig(:capabilities, :window, :workDoneProgress)
      end

      def process_message_from_client(message)
        Steep.logger.info "Processing message from client: method=#{message[:method]}, id=#{message[:id]}"
        id = message[:id]

        case message[:method]
        when "initialize"
          @initialize_params = message[:params]
          result_controller << group_request do |group|
            each_worker do |worker|
              group << send_request(method: "initialize", params: message[:params], worker: worker)
            end

            group.on_completion do
              controller.load(command_line_args: commandline_args)

              job_queue << SendMessageJob.to_client(
                message: {
                  id: id,
                  result: LSP::Interface::InitializeResult.new(
                    capabilities: LSP::Interface::ServerCapabilities.new(
                      text_document_sync: LSP::Interface::TextDocumentSyncOptions.new(
                        change: LSP::Constant::TextDocumentSyncKind::INCREMENTAL,
                        save: LSP::Interface::SaveOptions.new(include_text: false),
                        open_close: true
                      ),
                      hover_provider: {
                        workDoneProgress: true,
                        partialResults: true,
                        partialResult: true
                      },
                      completion_provider: LSP::Interface::CompletionOptions.new(
                        trigger_characters: [".", "@"],
                        work_done_progress: true
                      ),
                      workspace_symbol_provider: true,
                      definition_provider: true,
                      declaration_provider: false,
                      implementation_provider: true,
                      type_definition_provider: false
                    )
                  )
                }
              )
            end
          end

        when "initialized"
          if typecheck_automatically
            if request = controller.make_request(include_unchanged: true)
              start_type_check(request, last_request: nil, start_progress: request.total > 10)
            end
          end

        when "textDocument/didChange"
          broadcast_notification(message)
          path = pathname(message[:params][:textDocument][:uri])
          controller.push_changes(path)

        when "textDocument/didSave"
          if typecheck_automatically
            if request = controller.make_request(last_request: current_type_check_request)
              start_type_check(
                request,
                last_request: current_type_check_request,
                start_progress: request.total > 10
              )
            end
          end

        when "textDocument/didOpen"
          path = pathname(message[:params][:textDocument][:uri])
          controller.update_priority(open: path)

        when "textDocument/didClose"
          path = pathname(message[:params][:textDocument][:uri])
          controller.update_priority(close: path)

        when "textDocument/hover", "textDocument/completion"
          if interaction_worker
            result_controller << send_request(method: message[:method], params: message[:params], worker: interaction_worker) do |handler|
              handler.on_completion do |response|
                job_queue << SendMessageJob.to_client(
                  message: {
                    id: message[:id],
                    result: response[:result]
                  }
                )
              end
            end
          end

        when "workspace/symbol"
          result_controller << group_request do |group|
            typecheck_workers.each do |worker|
              group << send_request(method: "workspace/symbol", params: message[:params], worker: worker)
            end

            group.on_completion do |handlers|
              result = handlers.flat_map(&:result)
              job_queue << SendMessageJob.to_client(message: { id: message[:id], result: result })
            end
          end

        when "workspace/executeCommand"
          case message[:params][:command]
          when "steep/stats"
            result_controller << group_request do |group|
              typecheck_workers.each do |worker|
                group << send_request(method: "workspace/executeCommand", params: message[:params], worker: worker)
              end

              group.on_completion do |handlers|
                stats = handlers.flat_map(&:result)
                job_queue << SendMessageJob.to_client(
                  message: {
                    id: message[:id],
                    result: stats
                  }
                )
              end
            end
          end

        when "textDocument/definition", "textDocument/implementation"
          result_controller << group_request do |group|
            typecheck_workers.each do |worker|
              group << send_request(method: message[:method], params: message[:params], worker: worker)
            end

            group.on_completion do |handlers|
              links = handlers.flat_map(&:result)
              job_queue << SendMessageJob.to_client(
                message: {
                  id: message[:id],
                  result: links
                }
              )
            end
          end

        when "$/typecheck"
          request = controller.make_request(
            guid: message[:params][:guid],
            last_request: current_type_check_request,
            include_unchanged: true
          )

          if request
            start_type_check(
              request,
              last_request: current_type_check_request,
              start_progress: true
            )
          end

        when "shutdown"
          result_controller << group_request do |group|
            each_worker do |worker|
              group << send_request(method: "shutdown", worker: worker)
            end

            group.on_completion do
              job_queue << SendMessageJob.to_client(message: { id: message[:id], result: nil })
            end
          end

        when "exit"
          broadcast_notification(message)
        end
      end

      def process_message_from_worker(message, worker:)
        Steep.logger.tagged "#process_message_from_worker (worker=#{worker.name})" do
          Steep.logger.info { "Processing message from worker: method=#{message[:method] || "-"}, id=#{message[:id] || "*"}" }

          case
          when message.key?(:id) && !message.key?(:method)
            Steep.logger.tagged "response(id=#{message[:id]})" do
              Steep.logger.error { "Received unexpected response" }
              Steep.logger.debug { "result = #{message[:result].inspect}" }
            end
          when message.key?(:method) && !message.key?(:id)
            case message[:method]
            when "$/typecheck/progress"
              on_type_check_update(
                guid: message[:params][:guid],
                path: Pathname(message[:params][:path])
              )
            else
              # Forward other notifications
              job_queue << SendMessageJob.to_client(message: message)
            end
          end
        end
      end

      def start_type_check(request, last_request:, start_progress:)
        Steep.logger.tagged "#start_type_check(#{request.guid}, #{last_request&.guid}" do
          if last_request
            Steep.logger.info "Cancelling last request"

            job_queue << SendMessageJob.to_client(
              message: {
                method: "$/progress",
                params: {
                  token: last_request.guid,
                  value: { kind: "end" }
                }
              }
            )
          end

          if start_progress
            Steep.logger.info "Starting new progress..."

            @current_type_check_request = request

            if work_done_progress_supported?
              job_queue << SendMessageJob.to_client(
                message: {
                  id: fresh_request_id,
                  method: "window/workDoneProgress/create",
                  params: { token: request.guid }
                }
              )
            end

            job_queue << SendMessageJob.to_client(
              message: {
                method: "$/progress",
                params: {
                  token: request.guid,
                  value: { kind: "begin", title: "Type checking", percentage: 0 }
                }
              }
            )

            if request.finished?
              job_queue << SendMessageJob.to_client(
                message: {
                  method: "$/progress",
                  params: { token: request.guid, value: { kind: "end" } }
                }
              )
            end
          else
            @current_type_check_request = nil
          end

          Steep.logger.info "Sending $/typecheck/start notifications"
          typecheck_workers.each do |worker|
            assignment = Services::PathAssignment.new(max_index: typecheck_workers.size, index: worker.index)

            job_queue << SendMessageJob.to_worker(
              worker,
              message: {
                method: "$/typecheck/start",
                params: request.as_json(assignment: assignment)
              }
            )
          end
        end
      end

      def on_type_check_update(guid:, path:)
        if current = current_type_check_request()
          if current.guid == guid
            current.checked(path)
            Steep.logger.info { "Request updated: checked=#{path}, unchecked=#{current.unchecked_paths.size}" }
            percentage = current.percentage
            value = if percentage == 100
                      { kind: "end" }
                    else
                      progress_string = ("▮"*(percentage/5)) + ("▯"*(20 - percentage/5))
                      { kind: "report", percentage: percentage, message: "#{progress_string}" }
                    end

            job_queue << SendMessageJob.to_client(
              message: {
                method: "$/progress",
                params: { token: current.guid, value: value }
              }
            )

            @current_type_check_request = nil if current.finished?
          end
        end
      end

      def broadcast_notification(message)
        Steep.logger.info "Broadcasting notification #{message[:method]}"
        each_worker do |worker|
          job_queue << SendMessageJob.new(dest: worker, message: message)
        end
      end

      def send_notification(message, worker:)
        Steep.logger.info "Sending notification #{message[:method]} to #{worker.name}"
        job_queue << SendMessageJob.new(dest: worker, message: message)
      end

      def fresh_request_id
        SecureRandom.alphanumeric(10)
      end

      def send_request(method:, id: fresh_request_id(), params: nil, worker:, &block)
        Steep.logger.info "Sending request #{method}(#{id}) to #{worker.name}"

        message = { method: method, id: id, params: params }
        ResultHandler.new(request: message).tap do |handler|
          yield handler if block_given?
          job_queue << SendMessageJob.to_worker(worker, message: message)
        end
      end

      def group_request()
        GroupHandler.new().tap do |group|
          yield group
        end
      end

      def kill
        each_worker do |worker|
          worker.kill
        end
      end
    end
  end
end
