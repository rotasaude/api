# Único command que atravessa control plane (bypass) e data plane (with_tenant).
# Ver ADR-0024.
class ProvisionMunicipality
  def self.call(name:, ibge_code:, slug:, uf: nil,
                channel:, admin_email:, invited_by:,
                terms:, alert:, template: nil)
    municipality = nil

    # 1a. Control plane: cria município e canal (sem eventos, sem tenant ainda)
    ApplicationRecord.connected_to(role: :admin) do
      municipality = Municipality.create!(
        name: name, ibge_code: ibge_code, slug: slug, uf: uf, status: "active"
      )

      MunicipalityChannel.create!(
        municipality: municipality,
        phone_number_id: channel.fetch(:phone_number_id),
        waba_id: channel.fetch(:waba_id),
        display_phone_number: channel.fetch(:display_phone_number),
        access_token: channel.fetch(:access_token),
        active: true
      )
    end

    # 1b. Convite do 1º admin — InviteMember.call dispara DomainEvents.publish
    #     que exige Current.municipality_id + SET LOCAL (ADR-0020).
    with_tenant(municipality.id) do
      InviteMember.call(
        email: admin_email,
        role: "municipal_admin",
        municipality_id: municipality.id,
        invited_by: invited_by
      )
    end

    # 1c. Auditoria platform-scope (municipality_id: nil). Mocked em test.
    ApplicationRecord.connected_to(role: :admin) do
      Platform.audit("municipality.provisioned",
                     municipality_id: municipality.id, ibge_code: ibge_code, by: invited_by.id)
    end

    # 2. Data plane: seeds sob o tenant recém-criado
    with_tenant(municipality.id) do
      ConsentTerm.create!(
        municipality_id: municipality.id,
        version: terms.fetch(:version, "v1"),
        body: terms.fetch(:body),
        published_at: Time.current
      )

      Array(alert).each do |a|
        AlertRecipient.create!(
          municipality_id: municipality.id,
          channel: a.fetch(:channel),
          destination: a.fetch(:destination),
          escalation_order: a.fetch(:escalation_order, 0),
          active: true
        )
      end

      SeedProtocol.call(municipality: municipality, template: template) if template
    end

    Result.ok(municipality: municipality)
  rescue ActiveRecord::RecordInvalid => e
    Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
  end

  def self.with_tenant(municipality_id)
    ApplicationRecord.transaction do
      Current.municipality_id = municipality_id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", municipality_id])
      )
      yield
    end
  end
end
