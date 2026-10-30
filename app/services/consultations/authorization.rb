# app/services/consultations/authorization.rb
# Papel health_professional, vínculo ativo e CBO permitido para o tipo de
# consulta (ADR 0031; ADR 0046, Desvio 1). `kind:` "general" (padrão, o
# sentido de antes do módulo 28), "dental" ou :any (qualquer tipo: a leitura
# do prontuário de quem espera na unidade). `role:` (:dentist) restringe ao
# papel odontológico do CBO (registro inicial). Chame DENTRO da transação do
# comando: o FOR SHARE no vínculo faz o encerramento esperar (como
# Professionals::ClinicalAuthorization).
module Consultations
  module Authorization
    module_function

    def link_for(user:, health_unit_id:, kind: "general", role: nil)
      return [ :missing_role, nil ] unless user&.has_role?("health_professional")

      links = active_links(user).where(health_unit_id: health_unit_id.to_s).lock("FOR SHARE OF professional_links").to_a
      pick(links, kind, role)
    end

    # Para a abertura e o adendo de terceiro: um vínculo permitido em qualquer unidade.
    def any_allowed_link(user:, kind: "general")
      return [ :missing_role, nil ] unless user&.has_role?("health_professional")

      pick(active_links(user).to_a, kind, nil)
    end

    def any_link(user:) = any_allowed_link(user: user).first

    # Todos os vínculos ativos com CBO permitido (sem trava): as opções da consulta.
    def allowed_links(user:, kind: "general")
      return [] unless user&.has_role?("health_professional")

      active_links(user).to_a.select { |link| allowed?(link, kind, nil) }
    end

    def active_links(user)
      ProfessionalLink.active.joins(:professional).where(professionals: { user_id: user.id }).order(:started_at, :id)
    end

    def pick(links, kind, role)
      return [ :missing_link, nil ] if links.empty?

      allowed = links.find { |link| allowed?(link, kind, role) }
      allowed ? [ :ok, allowed ] : [ :cbo_not_allowed, nil ]
    end

    def allowed?(link, kind, role)
      return false if role && Cbos.role(link.cbo_code) != role

      kind == :any ? Cbos.kinds_for(link.cbo_code).any? : Cbos.allowed?(link.cbo_code, kind: kind)
    end
    private_class_method :active_links, :pick, :allowed?
  end
end
