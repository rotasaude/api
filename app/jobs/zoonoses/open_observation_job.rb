# Consumidor de disease_notification.{created,updated,transitioned} (módulo
# 35b, ADR 0054; contrato §5, Q16; molde do VectorControl::ProposeBlockJob).
# O gate `zoonoses` é lido aqui, antes da transação da cidade do
# IdempotentConsumer. Age só com o gate utilizável, a doença
# acidente_animal_raiva e a notificação `notified` ou `investigating` (a
# possível espera passar a notified; closed/entered/dismissed não agem: o
# dismissed só parte de possible, e a observação nunca nasce de possible,
# Q16). As regras da ficha (cão ou gato observável "true", exposure_on) e a
# abertura idempotente pelo único da notificação são do
# Zoonoses::OpenObservation: a ficha editada depois de aberta a observação
# não abre outra nem muda ends_on (Review Focus 3). O payload traz só ids; o
# job relê a linha. Nunca atribui Current.city.
module Zoonoses
  class OpenObservationJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def perform(city_slug:, **rest)
      city = City.find_by(slug: city_slug)
      @zoonoses = !city.nil? && Gate.usable?(city) # fora da transação da cidade
      super(city_slug: city_slug, **rest)
    end

    def handle(notification_id:, **)
      return unless @zoonoses

      notification = DiseaseNotification.find_by(id: notification_id)
      return unless notification&.disease_code == Catalog::OBSERVATION_DISEASE
      return unless Catalog::OBSERVATION_STATUSES.include?(notification.status)

      OpenObservation.call(notification: notification, parameters: Parameters.current.values)
    end
  end
end
