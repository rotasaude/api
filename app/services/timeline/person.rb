# "A pessoa" da linha do tempo (ADR 0035; spec §3): os pares VALIDADOS e não
# excluídos do CPF — no modo record também os ligados ao paciente do 19a —
# e o paciente, quando existe. Par só declarado nunca entra; para o cidadão
# de par declarado no wpda, a pessoa é só o próprio par (verified: false).
module Timeline
  Person = Data.define(:citizen_ids, :patient_id, :verified) do
    def self.verified_pairs = Citizen.not_erased.verification_level_verified

    def self.for_patient(patient)
      ids = verified_pairs.where(patient_id: patient.id).or(verified_pairs.where(cpf: patient.cpf))
                          .order(:created_at, :id).pluck(:id)
      new(citizen_ids: ids, patient_id: patient.id, verified: true)
    end

    def self.for_cpf(cpf)
      digits = cpf.is_a?(String) ? CitizenIdentity::Cpf.normalize(cpf) : nil
      return new(citizen_ids: [], patient_id: nil, verified: true) unless digits

      patient = Patient.find_by(cpf: digits)
      return for_patient(patient) if patient

      new(citizen_ids: verified_pairs.where(cpf: digits).order(:created_at, :id).pluck(:id), patient_id: nil, verified: true)
    end

    def self.for_citizen(citizen)
      return for_cpf(citizen.cpf) if citizen.verification_level_verified? && citizen.erased_at.nil?

      new(citizen_ids: [ citizen.id ], patient_id: nil, verified: false)
    end

    def empty? = citizen_ids.empty? && patient_id.nil?

    # Referência da pessoa na trilha: só id.
    def ref = patient_id ? "patient:#{patient_id}" : "citizen:#{citizen_ids.min}"

    def display_name
      patient = patient_id && Patient.find_by(id: patient_id)
      return patient.display_name if patient

      Citizen.where(id: citizen_ids).order(created_at: :desc).first&.display_name
    end
  end
end
