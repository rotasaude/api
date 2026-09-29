require_relative "campaign_history"

# Semente de dev do módulo 12 (spec 2026-09-29 §10). Dev é fictício, mas imita
# o real: bairros reais da TerritoryCrew, unidades do ProfessionalCrew, CPF com
# dígito válido, histórico coerente (a falta tem pedido reaberto; o retorno tem
# pedido aberto; o atendimento tem triagem). O histórico no passado é gravado
# pelo CampaignHistory (os comandos recusam data passada); o opt-in passa pelo
# comando do domínio. Idempotente. A chave de SMS da cidade fica desligada.
class CampaignCrew
  SECRET_ENV = "DEV_CAMPAIGN_MANAGER_OTP_SECRET"
  DEFAULT_SECRET = "MNQW24DBNZUGC4ZNMRSXMLLSN52GCIJB"

  # [bairro, unidade onde a pessoa é atendida]
  PLACES = {
    "curitiba" => [ [ "Boqueirão", "UBS Vila Esperança" ], [ "Santa Felicidade", "UBS Jardim das Flores" ] ],
    "maringa" => [ [ "Zona 07", "UBS Jardim das Flores" ], [ "Jardim Alvorada", "UBS Vila Esperança" ] ]
  }.freeze

  # 3 faltas por bairro: dois bairros juntos passam do mínimo; um só, não.
  CASES = %i[no_show no_show no_show incomplete incomplete open_request open_request
             discharged referred return left triaged_only].freeze

  class << self
    def seed_current_city(slug:, ddd:, password:)
      account = ensure_manager(slug: slug, password: password)
      by = User.find_by(email_address: "profissional@#{slug}.demo") || User.find_by!(email_address: "recepcao@#{slug}.demo")
      referral_target = HealthUnit.find_by(name: "UPA 24h Centro")
      citizens = 0
      new_histories = 0

      PLACES.fetch(slug, []).each_with_index do |(neighborhood_name, unit_name), place|
        neighborhood = Neighborhood.named(neighborhood_name).first ||
                       raise("semente: bairro #{neighborhood_name} ausente (rode Territory::Seed antes)")
        unit = HealthUnit.find_by(name: unit_name) || raise("semente: unidade #{unit_name} ausente (rode ProfessionalCrew antes)")
        CASES.each_with_index do |kind, i|
          index = place * CASES.size + i
          citizen = CampaignHistory.citizen!(cpf: CampaignHistory.cpf_for("#{slug}:campaign:#{index}"),
                                             phone: phone_for(ddd, index), neighborhood: neighborhood)
          citizens += 1
          new_histories += 1 if history!(citizen, kind, index, unit: unit, target: referral_target || unit, by: by)
          opt_in!(citizen) if index.even?
        end
      end

      if (first = PLACES.fetch(slug, []).first)
        shared = CampaignHistory.citizen!(cpf: CampaignHistory.cpf_for("#{slug}:campaign:shared"), phone: phone_for(ddd, 0),
                                          neighborhood: Neighborhood.named(first[0]).first)
        citizens += 1
        new_histories += 1 if history!(shared, :no_show, 0, unit: HealthUnit.find_by!(name: first[1]), target: nil, by: by)
      end

      { account: account, citizens: citizens, opted_in: CitizenContactPreference.where(sms_opt_in: true).count,
        new_histories: new_histories }
    end

    private

    def ensure_manager(slug:, password:)
      user = User.find_or_initialize_by(email_address: "campanhas@#{slug}.demo")
      user.password = password
      user.save!
      Membership.find_or_create_by!(user: user, role: "campaign_manager") { |m| m.granted_at = Time.current }
      SignatureCrew.ensure_totp(user, secret_env: SECRET_ENV, default_secret: DEFAULT_SECRET)
      { email: user.email_address, role: "campaign_manager", otpauth_uri: SignatureCrew.otpauth_uri(user) }
    end

    # true quando gravou o histórico agora; quem já tem conversa fica como está.
    def history!(citizen, kind, index, unit:, target:, by:)
      return false if Conversation.exists?(citizen_id: citizen.id)

      at = (Time.zone.today - (5 + (index % 20))).in_time_zone.change(hour: 9)
      case kind
      when :no_show then CampaignHistory.no_show!(citizen, at: at, unit: unit, by: by)
      when :incomplete
        CampaignHistory.triage!(citizen, status: index.odd? ? "aborted_by_timeout" : "aborted_by_cancellation", at: at)
      when :open_request
        CampaignHistory.request!(citizen, kind: index.odd? ? "return" : "referral", unit: unit, target: target, by: by, at: at)
      when :return then CampaignHistory.request!(citizen, kind: "return", unit: unit, by: by, at: at)
      when :triaged_only then CampaignHistory.triage!(citizen, tier: index.odd? ? "alta" : "baixa", at: at)
      else CampaignHistory.attendance!(citizen, outcome: kind.to_s, at: at, unit: unit, by: by)
      end
      true
    end

    def opt_in!(citizen)
      Citizens::UpdateContactPreferences.call(citizen: citizen, changes: { "sms_opt_in" => true })
    end

    def phone_for(ddd, index)
      format("+55%s96666%04d", ddd, index + 1)
    end
  end
end
