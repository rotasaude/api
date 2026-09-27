# Specs sem fixture transacional (threads) commitam de verdade em TEST_CITY_A.
# As tabelas do módulo 10, memberships, users e domain_events recusam DELETE
# por trigger; a suíte conecta como superusuário e desliga os triggers SÓ na
# transação da limpeza (mesmo recurso de invite_admin_spec.rb).
module CommittedRowsCleanup
  def purge_committed_rows(ids)
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        professional_ids = Professional.where(user_id: ids.values_at(:doctor, :doc_user).compact).pluck(:id)
        ProfessionalShift.where(professional_id: professional_ids).delete_all
        ProfessionalLink.where(professional_id: professional_ids).delete_all
        DomainEvent.where("payload->>'professional_id' IN (?)", professional_ids.presence || [ "" ]).delete_all
        Professional.where(id: professional_ids).delete_all
        user_ids = ids.values_at(:admin, :doctor, :doc_user).compact
        Session.where(user_id: user_ids).delete_all
        Membership.where(user_id: user_ids).delete_all
        User.where(id: user_ids).delete_all
        HealthUnit.where(id: ids[:unit]).delete_all
      end
    end
  end
end

RSpec.configure { |c| c.include CommittedRowsCleanup }
