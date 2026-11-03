# Papéis do TFD (ADR 0048; plano, Desvio 10): a comissão pela Membership
# `tfd_committee` ativa; o médico autor pela Membership `health_professional`
# e um vínculo ATIVO com CBO 225* (o mais antigo, que vai para
# `requester_cbo` quando o laudo não nasce de uma consulta).
module Tfd
  module Access
    module_function

    def committee?(user) = Transport::Access.committee?(user)

    # -> "225…" do vínculo ativo mais antigo | nil (sem o papel ou sem vínculo 225*).
    def physician_cbo(user)
      return nil unless user.present? && user.has_role?("health_professional")

      ProfessionalLink.active.joins(:professional).where(professionals: { user_id: user.id })
                      .where("professional_links.cbo_code LIKE ?", "#{Catalog::PHYSICIAN_PREFIX}%")
                      .order(:started_at, :id).pick(:cbo_code)
    end
  end
end
