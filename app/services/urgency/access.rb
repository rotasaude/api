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

    # Quem lê o clínico do encontro: o classificador ou o médico da UPA.
    def clinical_link(user, health_unit_id)
      link(user, health_unit_id, Catalog::CLASSIFIER_CBO_PREFIXES + [ Catalog::PHYSICIAN_CBO_PREFIX ])
    end

    def link(user, health_unit_id, prefixes)
      return nil if user.blank? || health_unit_id.blank? || !user.has_role?("health_professional")

      cbo = prefixes.map { |prefix| ProfessionalLink.arel_table[:cbo_code].matches("#{prefix}%") }.reduce(:or)
      ProfessionalLink.active.joins(:professional)
                      .where(professionals: { user_id: user.id }, health_unit_id: health_unit_id)
                      .where(cbo).order(:started_at, :id).first
    end
    private_class_method :link
  end
end
