require_relative "clinical_record_crew"

# Semente de dev do módulo 20 (ADR 0035). Dev é fictício mas imita o real:
# patient_timeline ligado em todas as cidades pelo mantenedor de dev; Maringá
# vira a cidade INTEGRADA (record_mode integrated pelo comando do console),
# com pec_external_view ligado, a origem do simulador do PEC, uma chave de dev
# e um CNES fictício na unidade da enfermeira; a cidadã validada da semente
# do prontuário ganha um atendimento lá. Idempotente. Roda por último.
# A chave de dev (override por DEV_PEC_HMAC_KEY) vai só para a cidade: nunca
# é impressa, logada nem devolvida no resultado.
class TimelineCrew
  DEV_MAINTAINER = "dev@local".freeze
  INTEGRATED = "maringa".freeze
  PEC_ORIGIN = "http://pec-sim.localhost:3040".freeze
  KEY_ENV = "DEV_PEC_HMAC_KEY".freeze
  DEFAULT_KEY = "dev-pec-hmac-key-maringa-0123456789".freeze
  DEV_CNES = "7700001".freeze

  class << self
    def seed_current_city(slug:, ddd:)
      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      return { switch: "desligado (sem mantenedor #{DEV_MAINTAINER})" } unless maintainer

      city = City.find(Current.city.id)
      Platform::Features.set!(city: city, key: "patient_timeline", enabled: true, maintainer: maintainer)
      return { switch: "patient_timeline ligado (#{city.record_mode})" } unless slug == INTEGRATED

      integrate!(city, maintainer, slug, ddd)
    end

    private

    def integrate!(city, maintainer, slug, ddd)
      unless city.record_mode == "integrated"
        updated = UpdateCityRecordSettings.call(city: city, attrs: { record_mode: "integrated" })
        raise "semente da linha do tempo: modo integrado recusado (#{updated.reason})" if updated.failure?
      end
      Platform::Features.set!(city: city, key: "pec_external_view", enabled: true, maintainer: maintainer)
      configure_pec!
      nurse = User.find_by!(email_address: "enfermeira@#{slug}.demo")
      unit = nurse.professional.links.active.order(:started_at).first!.health_unit
      unit.update!(cnes: DEV_CNES) if unit.cnes.blank?
      citizen = ClinicalRecordCrew.send(:ensure_citizen, slug, ddd)
      unless Attendance.exists?(citizen_id: citizen.id, health_unit_id: unit.id)
        ClinicalRecordCrew.send(:checked_in!, slug, unit, citizen, "linha-do-tempo")
      end
      { switch: "patient_timeline e pec_external_view ligados (integrated)", unit: unit.name, cnes: unit.cnes,
        simulator: "#{PEC_ORIGIN}/pec-simulator?city=#{slug}" }
    end

    # Pelo mesmo comando do maintenance (validação do formato incluída); só
    # grava o que falta, para não girar a chave a cada db:seed.
    def configure_pec!
      setting = PecSetting.current
      unless setting&.pec_origin.present?
        origin = PecExternal::Configure.set_origin(origin: PEC_ORIGIN)
        raise "semente da linha do tempo: origem do PEC recusada (#{origin.reason})" if origin.failure?
      end
      return if setting&.hmac_key_configured?

      key = PecExternal::Configure.rotate_key(key: ENV.fetch(KEY_ENV, DEFAULT_KEY))
      raise "semente da linha do tempo: chave do PEC recusada (#{key.reason})" if key.failure?
    end
  end
end
