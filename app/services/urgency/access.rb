# Papéis da urgência (ADR 0050; contrato §1 e §14 Q2): nenhum papel novo.
# A recepção é o citizen_verifier; a classificação, o health_professional com
# vínculo ATIVO na UPA e CBO de enfermagem (2235*); o atendimento médico, o
# mesmo com CBO 225*. O vínculo mais antigo (started_at, id) é o que vale.
module Urgency
  module Access
    module_function

    def reception?(user) = user.present? && user.has_role?("citizen_verifier")

    # -> ProfessionalLink | nil
    def classifier_link(user, health_unit_id) = link(user, health_unit_id, Catalog::CLASSIFIER_CBO_PREFIXES)
    def physician_link(user, health_unit_id) = link(user, health_unit_id, [ Catalog::PHYSICIAN_CBO_PREFIX ])

    # Quem classifica na UPA (§14 Q2): sem health_professional → missing_role;
    # sem vínculo ativo na unidade → missing_link; com vínculo, mas fora do
    # 2235 (o médico, o técnico 3222) → cbo_not_allowed.
    # -> Result.ok(link:) | Result.fail(:missing_role | :missing_link | :cbo_not_allowed)
    def classifier(user, health_unit_id)
      found = classifier_link(user, health_unit_id)
      found ? Result.ok(link: found) : Result.fail(refusal(user, health_unit_id))
    end

    # A recusa de quem não tem o vínculo pedido na unidade: sem
    # health_professional → missing_role; sem vínculo ativo nela →
    # missing_link; com vínculo de outro CBO → cbo_not_allowed.
    def refusal(user, health_unit_id)
      return :missing_role unless user.present? && user.has_role?("health_professional")

      link(user, health_unit_id, [ "" ]) ? :cbo_not_allowed : :missing_link
    end

    # Módulo 32b (Q4): o médico (225*) com vínculo ativo em alguma UPA — quem
    # busca o medicamento da prescrição, que não pertence a uma unidade só.
    def upa_physician?(user)
      user.present? && user.has_role?("health_professional") && upa_links(user, [ Catalog::PHYSICIAN_CBO_PREFIX ]).exists?
    end

    # A recusa da busca sem unidade: sem health_professional → missing_role; com
    # vínculo ativo em UPA, mas de outro CBO → cbo_not_allowed; sem nenhum → missing_link.
    def upa_refusal(user)
      return :missing_role unless user.present? && user.has_role?("health_professional")

      upa_links(user, [ "" ]).exists? ? :cbo_not_allowed : :missing_link
    end

    # Módulo 32b (Q2): quem checa a medicação — enfermagem, técnico 3222 ou médico.
    def nursing_or_physician_link(user, health_unit_id) = link(user, health_unit_id, Catalog::CHECKER_CBO_PREFIXES)

    # Módulo 32b (Q3): quem lê o mapa de observação — a recepção (de qualquer
    # UPA) ou quem checa a medicação na unidade.
    def observation_reader?(user, health_unit_id)
      reception?(user) || nursing_or_physician_link(user, health_unit_id).present?
    end

    # Quem lê o clínico do encontro: o classificador ou o médico da UPA.
    def clinical_link(user, health_unit_id)
      link(user, health_unit_id, Catalog::CLASSIFIER_CBO_PREFIXES + [ Catalog::PHYSICIAN_CBO_PREFIX ])
    end

    # Módulo 32b (§12 Q8): quem evolui o encontro aberto — o médico (225*) com
    # vínculo ativo na UPA do atendimento, enquanto nem o encontro nem o
    # atendimento fecharam (lê o prontuário em contexto e escreve adendo na
    # consulta urgency). Com lock: true (dentro da transação do adendo), o
    # encontro FOR SHARE e o estado do atendimento relido depois: o desfecho
    # (attendance → encounter) e o Close do 13 esperam ou já se veem.
    def evolver?(user, attendance, lock: false)
      return false unless attendance&.walk_in?

      scope = UrgencyEncounter.where(attendance_id: attendance.id)
      encounter = lock ? scope.lock("FOR SHARE").first : scope.first
      return false if encounter.nil? || encounter.closed?

      status = lock ? Attendance.where(id: attendance.id).pick(:status) : attendance.status
      status != "closed" && physician_link(user, attendance.health_unit_id).present?
    end

    def link(user, health_unit_id, prefixes)
      return nil if user.blank? || health_unit_id.blank? || !user.has_role?("health_professional")

      cbo = prefixes.map { |prefix| ProfessionalLink.arel_table[:cbo_code].matches("#{prefix}%") }.reduce(:or)
      ProfessionalLink.active.joins(:professional)
                      .where(professionals: { user_id: user.id }, health_unit_id: health_unit_id)
                      .where(cbo).order(:started_at, :id).first
    end

    def upa_links(user, prefixes)
      cbo = prefixes.map { |prefix| ProfessionalLink.arel_table[:cbo_code].matches("#{prefix}%") }.reduce(:or)
      ProfessionalLink.active.joins(:professional, :health_unit)
                      .where(professionals: { user_id: user.id }, health_units: { kind: "upa" }).where(cbo)
    end
    private_class_method :link, :upa_links
  end
end
