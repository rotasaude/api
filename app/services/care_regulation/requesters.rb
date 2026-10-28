# Quem pode pedir o quê à regulação (ADR 0044; contrato §1): médico 225* pede
# tudo; enfermeiro 2235* só o que está na lista municipal (NurseRequestableItem);
# dentista 2232* só especialidade odontológica; o resto não pede.
module CareRegulation
  module Requesters
    module_function

    # -> :physician | :nurse | :dentist | nil, pelo prefixo do CBO.
    def kind(cbo)
      cbo = cbo.to_s
      if cbo.start_with?(Catalog::PHYSICIAN_PREFIX) then :physician
      elsif cbo.start_with?(Catalog::NURSE_PREFIX) then :nurse
      elsif cbo.start_with?(Catalog::DENTIST_PREFIX) then :dentist
      end
    end

    # -> :ok | :cbo_not_allowed
    def check(cbo:, target:)
      allowed = case kind(cbo)
                when :physician then true
                when :nurse then NurseRequestableItem.exists?(target_type: target.type, target_code: target.code)
                when :dentist then target.type == "specialty" && target.group == "dental"
                else false
                end
      allowed ? :ok : :cbo_not_allowed
    end
  end
end
