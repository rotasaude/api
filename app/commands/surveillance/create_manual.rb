# Notificação manual da vigilância (módulo 25, ADR 0043; contrato §5, K4, K6,
# K11): a equipe da vigilância notifica uma pessoa que não passou por consulta.
#
#   - Pessoa: exatamente uma de patient_id | citizen_id (par validado →
#     Patients::Resolve; não validado → citizen_not_verified) | new_patient
#     (Patients::CreateTyped, recusas com `new_patient.<campo>`). Duplicado
#     (K4, como o L28 do 24a): new_patient com nome + nascimento de paciente
#     já gravado → duplicate_suspected, salvo `duplicates_reviewed: true`
#     (conferido sob o mesmo lock consultivo da match_key do 24a).
#   - suspected_on: AAAA-MM-DD, não futura (senão invalid_request com
#     `field`: o K6 não tem motivo próprio); o instante da suspeita é o dia às
#     00:00 no fuso da cidade (Desvio 5). unit_id: qualquer unidade ativa
#     (invalid_unit). resident_elsewhere/residence_ibge: o IBGE de fora tem 7
#     dígitos e difere do da cidade (invalid_residence).
#   - Paciente (criado ou resolvido aqui) e notificação na MESMA transação: a
#     recusa da notificação desfaz o paciente. Ordem de travas: unidade →
#     match_key / CPF → paciente → (CreateNotification) paciente → consultivo
#     paciente×doença.
# Nome, CPF, CNS, mãe, nascimento, doença e sintomas nunca em log, evento,
# erro nem Result: as recusas levam só o caminho do campo.
module Surveillance
  module CreateManual
    PERSON_KEYS = %w[patient_id citizen_id new_patient].freeze
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    # params: corpo JSON (chaves texto). -> Result.ok(notification:) |
    # fail(:invalid_patient | :invalid_disease | :invalid_request | :invalid_symptoms_on | :invalid_unit |
    # :invalid_residence | :citizen_not_verified | :duplicate_suspected | :cpf_taken | :cns_taken | ...) |
    # os de CreateNotification (:already_notified com notification_id).
    def call(params:, by:)
      parsed = parse(params.to_h.stringify_keys)
      return parsed if parsed.failure?

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        result = write(parsed.payload, by)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def parse(params)
      person = parse_person(params)
      return person if person.failure?

      disease = params["disease_code"].is_a?(String) ? Diseases.find(params["disease_code"]) : nil
      return Result.fail(:invalid_disease) unless disease

      suspected_on = parse_date(params["suspected_on"])
      return Result.fail(:invalid_request, details: { field: "suspected_on" }) if suspected_on.nil? || suspected_on > Time.zone.today

      symptoms_on = params["symptoms_on"].nil? ? nil : parse_date(params["symptoms_on"])
      return Result.fail(:invalid_symptoms_on) if !params["symptoms_on"].nil? && (symptoms_on.nil? || symptoms_on > suspected_on)
      return Result.fail(:invalid_unit) unless params["unit_id"].is_a?(String) && params["unit_id"].match?(UUID)

      residence = parse_residence(params)
      return residence if residence.failure?

      Result.ok(person.payload.merge(disease: disease, suspected_on: suspected_on, symptoms_on: symptoms_on,
                                     unit_id: params["unit_id"]).merge(residence.payload))
    end

    def parse_person(params)
      given = PERSON_KEYS.select { |key| !params[key].nil? }
      return invalid_patient(given.second || "patient_id") unless given.one?

      key = given.first
      value = params[key]
      case key
      when "patient_id"
        uuid?(value) && Patient.exists?(id: value) ? Result.ok(person: :patient, patient_id: value) : invalid_patient(key)
      when "citizen_id"
        citizen = uuid?(value) && Citizen.find_by(id: value)
        citizen ? Result.ok(person: :citizen, citizen: citizen) : invalid_patient(key)
      else
        return invalid_patient(key) unless value.is_a?(Hash)

        reviewed = params.fetch("duplicates_reviewed", false)
        return invalid_patient("duplicates_reviewed") unless [ true, false ].include?(reviewed)

        Result.ok(person: :new, new_patient: value, duplicates_reviewed: reviewed)
      end
    end

    def parse_residence(params)
      elsewhere = params.fetch("resident_elsewhere", false)
      ibge = params["residence_ibge"]
      return Result.fail(:invalid_residence) unless [ true, false ].include?(elsewhere)
      return Result.fail(:invalid_residence) unless elsewhere ? valid_foreign_ibge?(ibge) : ibge.nil?

      Result.ok(resident_elsewhere: elsewhere, residence_ibge: ibge)
    end

    def valid_foreign_ibge?(ibge)
      ibge.is_a?(String) && ibge.match?(Catalog::IBGE) && ibge != CityProfile.current&.ibge_code
    end

    # nil | Date (só AAAA-MM-DD de um dia que existe).
    def parse_date(value)
      return nil unless value.is_a?(String) && value.match?(DATE)

      Date.iso8601(value)
    rescue Date::Error
      nil
    end

    def write(attrs, by)
      unit = HealthUnit.lock_active!(attrs[:unit_id])
      person = person!(attrs, by)
      return person if person.failure?

      CreateNotification.call(patient: person.payload.fetch(:patient), disease: attrs[:disease], origin: "manual", unit: unit,
                              suspected_at: attrs[:suspected_on].in_time_zone, by: by, symptoms_on: attrs[:symptoms_on],
                              resident_elsewhere: attrs[:resident_elsewhere], residence_ibge: attrs[:residence_ibge])
    rescue HealthUnit::Inactive
      Result.fail(:invalid_unit)
    end

    # -> Result.ok(patient:) | a recusa.
    def person!(attrs, by)
      case attrs[:person]
      when :patient then Result.ok(patient: Patient.find(attrs[:patient_id]))
      when :citizen then Patients::Resolve.call(attrs[:citizen])
      else create_typed!(attrs[:new_patient], attrs[:duplicates_reviewed], by)
      end
    end

    def create_typed!(new_patient, reviewed, by)
      typed = new_patient.to_h.stringify_keys
      key = typed.values_at("full_name", "birth_date").all?(String) && Patients::MatchKey.for(typed["full_name"], typed["birth_date"])
      # A mesma trava do 24a (a chave é um hash: nunca nome nem nascimento no SQL).
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{match_lock_key(key)})") if key
      return Result.fail(:duplicate_suspected) if !reviewed && duplicate?(typed)

      created = Patients::CreateTyped.call(attrs: typed, by: by)
      created.failure? ? typed_failure(created) : created
    end

    # Possível duplicado pela regra da busca (Patients::Duplicates); com CPF
    # digitado, só candidatos sem CPF (outro CPF é outra pessoa; o mesmo é cpf_taken).
    def duplicate?(typed)
      strings = %w[full_name birth_date mother_name cpf].map { |key| typed[key] }
      return false unless strings.all? { |value| value.nil? || value.is_a?(String) }

      Patients::Duplicates.call(full_name: strings[0], birth_date: strings[1], mother_name: strings[2], limit: 1,
                                only_without_cpf: strings[3].present?).any?
    end

    def match_lock_key(key) = Digest::SHA256.hexdigest("patients:match_key:#{key}")[0, 15].to_i(16)

    # As recusas do CreateTyped com o caminho do corpo (new_patient.*).
    def typed_failure(result)
      case result.reason
      when :invalid_cpf then invalid_patient("new_patient.cpf")
      when :invalid_cns then invalid_patient("new_patient.cns")
      when :cpf_or_reason_required then Result.fail(:cpf_or_reason_required, details: { path: "new_patient.no_cpf_reason" })
      else result
      end
    end

    def invalid_patient(path) = Result.fail(:invalid_patient, details: { path: path })
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    private_class_method :parse, :parse_person, :parse_residence, :valid_foreign_ibge?, :parse_date, :write, :person!, :create_typed!,
                         :duplicate?, :match_lock_key, :typed_failure, :invalid_patient, :uuid?
  end
end
