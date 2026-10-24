# Saída do cadastro individual (contrato §5, §14 L9; §15.2; F-24.3):
# `{ reason: moved|death, on: AAAA-MM-DD, death_on?, death_certificate? }`.
# `on` e `death_on` entre o nascimento e hoje; `death_on` obrigatório com
# death e proibido com moved; `death_certificate` (número da DO, 9 dígitos)
# opcional, só com death. Uma vez: cadastro que saiu, ou recusado (o LEDI
# proíbe saída com termo de recusa), → invalid_transition (422, L9).
# Escopo como a gravação: Access.registrar?(ficha: :individual) — o admin
# nunca (out_of_scope | cbo_not_allowed). Nova versão `exit` (as seções da
# última) + ficha; o cabeçalho congela (trigger); registered_at fica o da
# última gravação (a saída não conta). Evento territory_registration.exited.
module TerritoryRegistry
  module ExitRegistration
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    CERTIFICATE = /\A\d{9}\z/

    module_function

    def call(registration:, params:, by:)
      params = params.to_h.stringify_keys
      scope = Access.registrar?(by, registration.team, ficha: :individual, micro_area: registration.micro_area)
      return Result.fail(scope) unless scope == :ok

      parsed = parse(params, registration.patient)
      return parsed if parsed.failure?

      ApplicationRecord.transaction(requires_new: true) { write(registration, parsed.payload, by) }
    end

    def parse(params, patient)
      reason = params["reason"]
      return invalid("reason") unless Catalog::EXIT_REASONS.include?(reason)

      birth = date(patient.birth_date)
      on = date(params["on"])
      return invalid("on") unless within?(on, birth)

      death = reason == "death"
      death_on = date(params["death_on"])
      return invalid("death_on") if death ? !within?(death_on, birth) : !params["death_on"].nil?

      certificate = params["death_certificate"]
      return invalid("death_certificate") unless certificate.nil? || (death && certificate.is_a?(String) && certificate.match?(CERTIFICATE))

      Result.ok(exit_reason: reason, exited_on: on, death_on: death_on, death_certificate: certificate)
    end

    # Travas do Desvio 12: paciente → domicílio → família → cadastro.
    def write(registration, values, by)
      Patient.lock.find(registration.patient_id)
      Household.lock("FOR SHARE").find_by(id: registration.household_id) if registration.household_id
      Family.lock("FOR SHARE").find_by(id: registration.family_id) if registration.family_id
      registration.lock!
      return Result.fail(:invalid_transition) if registration.exited? || registration.refused?

      member = Access.membership(by, registration.team)
      version = SaveRegistration.append!(registration, origin: "exit", saved_by_user_id: by.id, saved_by_professional_id: by.professional.id,
                                                       saved_cbo: member.cbo_code, changes: values, header: values)
      DomainEvents.publish("territory_registration.exited", registration_id: registration.id, registration_version_id: version.id,
                                                            patient_id: registration.patient_id, user_id: by.id)
      Result.ok(registration: registration, version: version)
    end

    def within?(day, birth) = day && day <= Time.zone.today && (birth.nil? || day >= birth)

    def date(value)
      return value if value.is_a?(Date)

      Date.iso8601(value) if value.is_a?(String) && value.match?(DATE)
    rescue Date::Error
      nil
    end

    def invalid(path) = Result.fail(:invalid_registration, details: { path: path })
    private_class_method :parse, :write, :within?, :date, :invalid
  end
end
