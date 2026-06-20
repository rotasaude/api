# Marca, por consumidor, que um evento já foi consumido com sucesso.
# Índice único em (consumer, event_id) garante exactly-once. Ver ADR-0005.
class ProcessedEvent < ApplicationRecord
  validates :consumer, :event_id, presence: true
end
