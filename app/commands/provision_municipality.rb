# Provisiona os recursos de uma cidade JÁ registrada e servível no catálogo
# (banco criado e migrado). NÃO cria banco: o provisionamento em duas fases
# (POST /setup/cities → job sob rota_provisioner) é o Plano 4, e o endpoint HTTP
# que chamava este command fica desligado até lá (SetupController#
# provision_municipality). Ver ADR-0013.
#
# Onde cada coisa grava (spec banco-por-cidade §2/§3):
#   - PLATAFORMA: CityChannel e o evento municipality.provisioned (Platform.audit
#     só com city_id/ibge_code/by — nunca dado pessoal, Ruling R18);
#   - CIDADE (CityConnection.with): convite do 1º municipal_admin, termo de
#     consentimento, destinatários de alerta e protocolo template.
#
# `invited_by` precisa ser um User DESTA cidade: invitations.invited_by_id é FK
# para users do banco da cidade. Operador de plataforma convidando é o grant do
# Plano 3B.
class ProvisionMunicipality
  def self.call(city:, ibge_code:, channel:, admin_email:, invited_by:,
                terms:, alert:, template: nil)
    unless city.servable?
      return Result.fail(:city_not_servable, message: "cidade #{city.slug} não está ativa (status=#{city.status})")
    end

    # 1. Plataforma: canal da cidade.
    CityChannel.create!(
      city: city,
      phone_number_id: channel.fetch(:phone_number_id),
      waba_id: channel.fetch(:waba_id),
      display_phone_number: channel.fetch(:display_phone_number),
      access_token: channel.fetch(:access_token),
      active: true
    )

    # 2. Cidade: convite do 1º admin + seeds, atômicos no banco da cidade.
    invited = nil
    Current.set(city: city) do
      CityConnection.with(city) do
        ApplicationRecord.transaction do
          invited = InviteMember.call(email: admin_email, role: "municipal_admin", invited_by: invited_by)
          raise ActiveRecord::Rollback unless invited.ok?

          ConsentTerm.create!(
            version: terms.fetch(:version, "v1"),
            body: terms.fetch(:body),
            published_at: Time.current
          )

          Array(alert).each do |a|
            AlertRecipient.create!(
              channel: a.fetch(:channel),
              destination: a.fetch(:destination),
              escalation_order: a.fetch(:escalation_order, 0),
              active: true
            )
          end

          SeedProtocol.call(template: template) if template
        end
      end
    end
    return invited unless invited.ok?

    # 3. Plataforma: auditoria sobre o objeto de plataforma (a cidade).
    Platform.audit("municipality.provisioned", city_id: city.id, ibge_code: ibge_code, by: invited_by.id)

    Result.ok(city: city, invitation: invited.payload[:invitation])
  rescue ActiveRecord::RecordInvalid => e
    Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
  end
end
