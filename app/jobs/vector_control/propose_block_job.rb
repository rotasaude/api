# Consumidor de disease_notification.created e .transitioned (módulo 35a, ADR
# 0054; contrato §8, decisão 28). O gate `vector_control` é lido aqui, antes
# da transação da cidade do IdempotentConsumer (no padrão do
# `vector_control:` da visita). Age só com o gate utilizável, a notificação
# `notified` ou `investigating` (Q26(1): chegou a notified, ainda que a fila
# atrase; a possível da rede de segurança espera passar a notified, e
# closed/entered/dismissed não agem) e a doença em block_diseases (Parameters.current); o resto é
# VectorControl::Blocks::Propose, idempotente pelo caso único por
# notificação. O payload traz só ids; o job relê a linha. Nunca atribui
# Current.city.
module VectorControl
  class ProposeBlockJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    STATUSES = %w[notified investigating].freeze

    def perform(city_slug:, **rest)
      city = City.find_by(slug: city_slug)
      @vector_control = !city.nil? && Gate.usable?(city) # fora da transação da cidade
      super(city_slug: city_slug, **rest)
    end

    def handle(notification_id:, **)
      return unless @vector_control

      notification = DiseaseNotification.find_by(id: notification_id)
      return unless STATUSES.include?(notification&.status)

      parameters = Parameters.current.values
      return unless Array(parameters["block_diseases"]).include?(notification.disease_code)

      Blocks::Propose.call(notification: notification, parameters: parameters)
    end
  end
end
