# Quem faz o quê na atividade coletiva (módulo 24b, ADR 0052; contrato §7):
# registra o membro ativo da equipe (papel health_professional, vínculo sem
# ended_on) cujo CBO do vínculo está na Tabela 5 do LEDI; lê quem registra e o
# enfermeiro/médico da equipe (TerritoryRegistry::Catalog::REGISTRAR_CBO_PREFIXES);
# marca "por engano" só quem registrou.
module CollectiveActivities
  module Access
    module_function

    def registers?(user, team)
      member = TerritoryRegistry::Access.membership(user, team)
      member.present? && Catalog::CBOS.include?(member.cbo_code.to_s)
    end

    def reads?(user, team)
      return true if registers?(user, team)

      cbo = TerritoryRegistry::Access.membership(user, team)&.cbo_code.to_s
      cbo.present? && TerritoryRegistry::Catalog::REGISTRAR_CBO_PREFIXES.any? { |prefix| cbo.start_with?(prefix) }
    end

    def marker?(user, activity) = user.present? && activity.recorded_by_user_id == user.id
  end
end
