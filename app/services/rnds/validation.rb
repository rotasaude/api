# Validação NT 115 antes do envio à RNDS (ADR 0047, Desvio 16). Roda no job de
# envio, dentro do contexto da cidade.
#
#   Rnds::Validation.call(immunization:, entry:, city:) -> :ok | :retry_later | [:blocked, reason]
#
# Ordem: (1) paciente com CPF ou CNS (Review Focus 5: só CNS passa);
# (2) o CNS do vacinador está em CnesProfessionalBond do retrato mais recente do
# IBGE da cidade, no CNES da unidade da dose; (3) com `cadsus_lookup` utilizável
# e CPF, o CADSUS conhece o CPF — conferido uma vez por entrada
# (`identity_checked_at`). CADSUS fora do ar, credencial recusada ou banco da
# cidade inalcançável NÃO bloqueiam: :retry_later (o job reagenda com backoff).
#
# O CNS do vínculo é cifrado e sem chave de busca: compara em Ruby, carregando só
# os vínculos daquele CNES; `cache` (um Hash por rodada do job) memoiza por
# retrato+CNES. CPF, CNS e nome nunca saem daqui: o motivo é só o código.
module Rnds
  module Validation
    module_function

    def call(immunization:, entry:, city:, cache: {})
      patient = immunization.patient
      return blocked("patient_without_cns_or_cpf") if patient.cpf.blank? && patient.cns.blank?

      unless professional_in_cnes?(immunization, city, cache)
        return blocked("professional_cns_not_in_cnes")
      end

      identity(patient, entry, city)
    end

    def blocked(reason) = [ :blocked, reason ].tap { raise ArgumentError, "unknown block reason" unless Vaccination::Catalog::BLOCK_REASONS.include?(reason) }

    def professional_in_cnes?(immunization, city, cache)
      cns = immunization.vaccinator_user.professional&.cns.to_s.gsub(/\D/, "")
      cnes = immunization.health_unit.cnes
      return false if cns.empty? || cnes.blank?

      bond_cns(cnes, city, cache).include?(cns)
    end

    # CNS dos vínculos do CNES no retrato mais recente do IBGE da cidade.
    def bond_cns(cnes, city, cache)
      ibge = CityConnection.with(city) { CityProfile.current&.ibge_code }
      return [] if ibge.blank?

      cache[[ ibge, cnes ]] ||= begin
        snapshot = CnesSnapshot.where(ibge_code: ibge).order(competence: :desc).first
        snapshot ? snapshot.bonds.where(cnes: cnes).map { |bond| bond.cns.to_s.gsub(/\D/, "") }.reject(&:empty?) : []
      end
    end

    def identity(patient, entry, city)
      return :ok if patient.cpf.blank? || entry.identity_checked_at.present?
      return :ok unless Platform::Features.usable?(city, "cadsus_lookup")

      record = Cadsus::Client.for(city).lookup(patient.cpf)
      return blocked("patient_identity_unverified") if record.nil?

      entry.update!(identity_checked_at: Time.current)
      :ok
    rescue Cadsus::Error, *Maintenance::CityConnectionErrors::CLASSES, ActiveRecord::StatementInvalid
      :retry_later
    end

    private_class_method :blocked, :professional_in_cnes?, :bond_cns, :identity
  end
end
