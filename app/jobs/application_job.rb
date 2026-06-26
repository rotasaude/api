class ApplicationJob < ActiveJob::Base
  retry_on ActiveRecord::Deadlocked, attempts: 3, wait: :polynomially_longer
  discard_on ActiveJob::DeserializationError
end
