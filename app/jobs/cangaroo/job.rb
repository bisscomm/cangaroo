module Cangaroo
  class Job < ActiveJob::Base
    include Cangaroo::ClassConfiguration

    queue_as :cangaroo

    class_configuration :connection
    class_configuration :path, ''
    class_configuration :parameters, {}

    def perform(*)
      restart_flow(connection_request)
    end

    def perform?
      fail NotImplementedError
    end

    def transform
      { type.singularize => payload }
    end

    protected

    def connection_request
      # job ID will remain consistent across retries
      translation = Cangaroo::Translation.where(job_id: @job_id).first_or_initialize(
        # TODO use job in place of destination connection
        # TODO use source job is place of source connection
        # ^ this will provide more detail to the user

        source_connection: source_connection,
        destination_connection: destination_connection,

        object_type: self.type,

        request: self.payload
      )

      if translation.new_record?
        if self.payload['id']
          translation.object_key = 'id'
          translation.object_id = self.payload['id']
        elsif self.payload['internal_id']
          # TODO support dynamic proc based ID search here instead
          translation.object_key = 'internal_id'
          translation.object_id = self.payload['internal_id']
        else
          # TODO log
        end

        translation.save!
      end

      response = Cangaroo::Webhook::Client.new(destination_connection, path)
        .post(transform, @job_id, parameters, translation)

      translation.update_column :response, (response.blank?) ? {} : response

      response
    end

    def restart_flow(response)
      # if no json was returned, the response should be discarded
      return if response.blank?

      PerformFlow.call(
        source_connection: destination_connection,
        json_body: response.to_json,
        jobs: Rails.configuration.cangaroo.jobs
      )
    end

    def source_connection
      arguments.first.fetch(:connection)
    end

    def type
      arguments.first.fetch(:type)
    end

    def payload
      arguments.first.fetch(:payload)
    end

    def destination_connection
      @connection ||= Cangaroo::Connection.find_by!(name: connection)
    end
  end
end
