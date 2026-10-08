# Paciente do par (ADR 0031; spec §3): exige par VALIDADO; acha ou cria o
# paciente pelo CPF e liga o par. Duas consultas do mesmo CPF ao mesmo tempo
# (pares diferentes) criam UM paciente: lock consultivo por CPF (a chave é um
# hash — nunca o CPF no SQL nem no log), com o índice único de patients.cpf
# como última palavra. Ordem de travas de quem chama: atendimento → CPF →
# par → paciente. O perfil (nascimento, sexo) segue o par validado mais
# recente; o nome, o par validado mais recente que tem nome.
module Patients
  module Resolve
    module_function

    def call(citizen)
      return Result.fail(:citizen_not_verified) unless eligible?(citizen)

      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key(citizen.cpf)})")
        citizen.lock!
        next Result.fail(:citizen_not_verified) unless eligible?(citizen)

        patient = citizen.patient_id ? Patient.lock.find(citizen.patient_id) : Patient.lock.find_by(cpf: citizen.cpf)
        created = patient.nil?
        patient ||= Patient.create!(cpf: citizen.cpf)
        unless citizen.patient_id == patient.id
          citizen.update!(patient_id: patient.id)
          DomainEvents.publish(created ? "patient.created" : "patient.linked", patient_id: patient.id, citizen_id: citizen.id)
        end
        refresh!(patient)
        Result.ok(patient: patient, created: created)
      end
    end

    # Recalcula nome e perfil a partir dos pares validados ligados e registra
    # divergência de nascimento/sexo (uma vez por par e campos).
    def refresh!(patient)
      linked = Citizen.not_erased.verification_level_verified.where(patient_id: patient.id).includes(:verifications).to_a
      return patient if linked.empty?

      latest = linked.max_by { |c| recency(c) }
      named = linked.select { |c| c.full_name.present? }.max_by { |c| recency(c) }
      values = { birth_date: latest.birth_date, sex: latest.sex }
      values.merge!(full_name: named.full_name, social_name: named.social_name, mother_name: named.mother_name) if named
      patient.update!(values) if values.any? { |key, value| patient.public_send(key) != value }
      (linked - [ latest ]).each { |other| record_divergence!(patient, other, latest) }
      patient
    end

    def lock_key(cpf) = Digest::SHA256.hexdigest("patients:#{cpf}")[0, 15].to_i(16)

    def eligible?(citizen) = citizen.verification_level_verified? && citizen.erased_at.nil?

    def recency(citizen)
      verified_at = citizen.verifications.select(&:active?).map(&:verified_at).max
      [ verified_at || Time.zone.at(0), citizen.updated_at ]
    end

    def record_divergence!(patient, other, reference)
      fields = PatientProfileDivergence::FIELDS.select { |field| other.public_send(field) != reference.public_send(field) }
      return if fields.empty?
      return if PatientProfileDivergence.where(patient_id: patient.id, citizen_id: other.id)
                                        .where("fields = ARRAY[?]::text[]", fields).exists?

      PatientProfileDivergence.create!(patient: patient, citizen: other, fields: fields)
    end
    private_class_method :eligible?, :recency, :record_divergence!
  end
end
