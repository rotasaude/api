# Profissional no CNES local (ADR 0049; contrato §6, pendência
# professional_not_in_cnes): o retrato mais recente do CNES do IBGE da cidade
# (CityProfile.current, módulo 16) tem um vínculo com o mesmo CNES, o mesmo CBO
# e o mesmo CNS. Sem IBGE, sem retrato, sem CNS ou sem CNES → false.
#
# O CNS do vínculo é cifrado sem chave de busca (CnesProfessionalBond): compara
# em Ruby, carregando só os vínculos daquele CNES, como Rnds::Validation.
# `cache` (um Hash por leitura do mês) memoiza o retrato por CNES. CNS nunca sai
# daqui.
module Psychosocial
  module CnesCheck
    module_function

    def bonded?(cns:, cbo:, cnes:, cache: {})
      digits = cns.to_s.gsub(/\D/, "")
      return false if digits.empty? || cbo.blank? || cnes.blank?

      bonds(cnes, cache).include?([ digits, cbo ])
    end

    # -> Set de [CNS (só dígitos), CBO] dos vínculos do CNES no retrato mais recente.
    def bonds(cnes, cache)
      cache[cnes] ||= begin
        snapshot = latest_snapshot
        snapshot ? snapshot.bonds.where(cnes: cnes).to_set { |bond| [ bond.cns.to_s.gsub(/\D/, ""), bond.cbo_code ] } : Set.new
      end
    end

    def latest_snapshot
      ibge = CityProfile.current&.ibge_code
      ibge.present? ? CnesSnapshot.where(ibge_code: ibge).order(competence: :desc).first : nil
    end

    private_class_method :bonds, :latest_snapshot
  end
end
