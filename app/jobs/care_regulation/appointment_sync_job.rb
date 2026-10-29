# Consumidor dos eventos do módulo 17 para a rede própria da regulação (ADR
# 0044; contrato §7, §13 G1, G6; plano do api, Desvio 7). Cada evento só diz
# QUAL pedido de agendamento olhar; a reconciliação lê o estado atual
# (CareRegulation::AppointmentSync), então a ordem de chegada e o redespacho
# não importam. Idempotente por (consumidor, evento) no IdempotentConsumer,
# na transação da cidade (CityScopedJob). Roda com o interruptor em qualquer
# estado (R16). Nunca atribui Current.city.
module CareRegulation
  class AppointmentSyncJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    # Evento → id do pedido de agendamento (payloads só com ids).
    RESOLVERS = {
      "appointment.scheduled" => ->(p) { p[:appointment_request_id] },
      "appointment.checked_in" => ->(p) { p[:appointment_request_id] },
      "appointment.no_show" => ->(p) { p[:appointment_request_id] },
      "appointment.expired" => ->(p) { p[:appointment_request_id] },
      "appointment.booked" => ->(p) { p[:request_id] },
      "appointment.moved" => ->(p) { Appointment.where(id: p[:to_appointment_id]).pick(:request_id) },
      "appointment.cancelled" => ->(p) { Appointment.where(id: p[:appointment_id]).pick(:request_id) },
      "appointment_request.closed" => ->(p) { p[:appointment_request_id] },
      "appointment_request.moved" => ->(p) { p[:to_request_id] },
      # Rede de segurança (acréscimo do controlador): também no nascimento.
      "appointment_request.created" => ->(p) { p[:appointment_request_id] }
    }.freeze
    EVENTS = RESOLVERS.keys.freeze

    # O payload não diz de que evento veio: o nome fica para o handle.
    def perform(event_name:, **rest)
      @event_name = event_name
      super(event_name: event_name, **rest)
    end

    def handle(**payload)
      resolver = RESOLVERS.fetch(@event_name) { raise ArgumentError, "evento não consumido: #{@event_name}" }
      id = resolver.call(payload)
      return if id.blank?

      AppointmentSync.call(appointment_request_id: id)
    end
  end
end
