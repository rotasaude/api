# Fase 2 do provisionamento (spec banco-por-cidade §4, Plano 4). Roda no worker,
# o único processo com PROVISIONER_DATABASE_URL:
#   1. banco e role da cidade (CityDatabase.ensure!);
#   2. migrations, em subprocesso (CityMigrations::Subprocess), que grava
#      cities.schema_version;
#   3. no banco da cidade, numa transação: city_profile, destinatário de alerta,
#      protocolo template em rascunho e convite do primeiro municipal_admin
#      (convidado pela plataforma: invited_by nulo);
#   4. e-mail do convite, SÓ quando o convite nasceu nesta execução;
#   5. cidade → active e municipality.provisioned, numa transação de plataforma.
#
# Cada passo é idempotente: um retry (ou um novo POST /cities com o mesmo slug)
# retoma de onde parou sem duplicar nada. O e-mail vem antes da ativação: se a
# ativação falhar, o retry encontra o convite e não o reenvia. Cidade fora de
# provisioning é ignorada — ativa, suspensa ou arquivada não volta a ser
# provisionada.
#
# NÃO semeia consent_terms (Plano 4, decisão 8): Consents.current_version lê
# ConsentTerm.maximum(:version) e o texto do termo vem das credentials.
class ProvisionCityJob < ApplicationJob
  queue_as :default

  retry_on StandardError, attempts: 3, wait: :polynomially_longer

  class_attribute :migrator, default: CityMigrations::Subprocess

  class SeedFailed < StandardError; end

  def perform(city_id:, ibge_code:, admin_email:, alert_email:, operator_id:)
    city = City.find_by(id: city_id)
    return unless city&.status == "provisioning"

    CityDatabase.ensure!(slug: city.slug, password: URI.parse(city.database_url).password)
    migrator.call(city)
    city.reload

    token = seed(city, ibge_code: ibge_code, admin_email: admin_email, alert_email: alert_email)
    if token
      InvitationMailer.invite(email_address: admin_email,
                              accept_url: CityDashboardUrl.invitation(city, token: token)).deliver_later
    end

    PlatformRecord.transaction do
      city.update!(status: "active")
      Platform.audit("municipality.provisioned", city_id: city.id, ibge_code: ibge_code, by: operator_id)
    end
    CityCatalog.reset_cache!
  end

  private

  # Devolve o token do convite quando ele foi criado AGORA; nil se já existia.
  def seed(city, ibge_code:, admin_email:, alert_email:)
    token = nil

    Current.set(city: city) do
      CityConnection.with(city) do
        ApplicationRecord.transaction do
          CityProfile.create!(name: city.name, uf: city.uf, ibge_code: ibge_code) unless CityProfile.exists?

          unless AlertRecipient.exists?
            AlertRecipient.create!(channel: "email", destination: alert_email, escalation_order: 0, active: true)
          end

          template = CityTemplates.protocol
          SeedProtocol.call(template: template) unless ProtocolDefinition.exists?(name: template.fetch(:name))

          unless Invitation.exists?(email: admin_email.downcase, role: "municipal_admin")
            invited = InviteMember.call(email: admin_email, role: "municipal_admin", invited_by: nil)
            raise SeedFailed, "convite do primeiro municipal_admin: #{invited.message}" if invited.failure?

            token = invited.payload[:invitation].token
          end
        end
      end
    end

    token
  end
end
