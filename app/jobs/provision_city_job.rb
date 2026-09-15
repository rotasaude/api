# Fase 2 do provisionamento (spec banco-por-cidade §4, Plano 4). Roda no worker,
# o único processo com PROVISIONER_DATABASE_URL:
#   1. banco e role da cidade (CityDatabase.ensure!);
#   2. migrations, em subprocesso (CityMigrations::Subprocess), que grava
#      cities.schema_version;
#   3. no banco da cidade, numa transação: city_profile, destinatário de alerta,
#      protocolo template em rascunho e convite do primeiro municipal_admin
#      (convidado pela plataforma: invited_by nulo);
#   4. e-mail do convite, em TODA execução enquanto a cidade segue provisioning —
#      entrega pelo menos uma vez (fix round 1): um retry antes da ativação
#      reenvia o link do convite PENDENTE (mesmo token); um e-mail duplicado
#      carrega um convite igualmente válido. Convite vencido ou aceito não é
#      reaproveitado: nasce um novo. Depois que a cidade vira active, o guard do
#      início do método corta o envio;
#   5. cidade → active e municipality.provisioned, numa transação de plataforma.
#
# Banco/role e migrations são idempotentes: um retry (ou um novo POST /cities
# com o mesmo slug) os retoma sem duplicar nada. Cidade fora de provisioning é
# ignorada — ativa, suspensa ou arquivada não volta a ser provisionada.
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

    mail_args = seed(city, ibge_code: ibge_code, admin_email: admin_email, alert_email: alert_email)
    InvitationMailer.invite(**mail_args).deliver_later

    PlatformRecord.transaction do
      city.update!(status: "active")
      Platform.audit("municipality.provisioned", city_id: city.id, ibge_code: ibge_code, by: operator_id)
    end
    CityCatalog.reset_cache!
  end

  private

  # Devolve os argumentos do e-mail do convite PENDENTE (não aceito e não
  # vencido) do primeiro municipal_admin — criado agora ou em execução
  # anterior, tanto faz: é assim que o e-mail é reenviado num retry (fix round
  # 1). A lógica de reaproveitar-ou-criar mora em CityLifecycle::InviteAdmin
  # (compartilhada com a rake city:invite_admin — rodada de hardening,
  # pre-Plano 6); chamada AQUI DENTRO da mesma transação do resto do seed, para
  # falhar junto com ela (SeedFailed desfaz tudo, igual antes da extração).
  #
  # M3 (rodada de hardening, review): Current.city envolve o passo INTEIRO de
  # novo (era assim antes da extração de InviteAdmin) — não só a chamada a
  # InviteAdmin, que seta o seu próprio Current.city internamente mas só
  # durante a própria execução. CityProfile/AlertRecipient/SeedProtocol não
  # leem Current.city hoje, mas o seed inteiro roda na cidade da conexão, e
  # deixar Current.city refletir isso durante todo o passo é o comportamento
  # de antes — não uma correção de um bug observável hoje.
  def seed(city, ibge_code:, admin_email:, alert_email:)
    mail_args = nil

    Current.set(city: city) do
      CityConnection.with(city) do
        ApplicationRecord.transaction do
          CityProfile.create!(name: city.name, uf: city.uf, ibge_code: ibge_code) unless CityProfile.exists?

          unless AlertRecipient.exists?
            AlertRecipient.create!(channel: "email", destination: alert_email, escalation_order: 0, active: true)
          end

          template = CityTemplates.protocol
          SeedProtocol.call(template: template) unless ProtocolDefinition.exists?(name: template.fetch(:name))

          invited = CityLifecycle::InviteAdmin.call(city: city, email: admin_email)
          raise SeedFailed, "convite do primeiro municipal_admin: #{invited.message}" if invited.failure?

          mail_args = invited.payload[:mail_args]
        end
      end
    end

    mail_args
  end
end
