require "zlib"

# Semente de dev do módulo 10 (spec 2026-09-27-module-10-professionals §6).
# Dev é fictício, mas imita o real: CBO reais, CNS com dígito verificador
# válido, conselho coerente com a ocupação, UF da cidade, plantão noturno e de
# 24h, uma pessoa em duas unidades com ocupações diferentes, um vínculo
# encerrado e alguém com o papel sem cadastro. Tudo pelos comandos do domínio,
# para as validações rodarem. Idempotente. Roda depois do SignatureCrew, que
# cria profissional@ e recepcao@.
class ProfessionalCrew
  UNITS = [
    { name: "UBS Jardim das Flores", kind: "ubs" },
    { name: "UBS Vila Esperança", kind: "ubs" },
    { name: "UPA 24h Centro", kind: "upa" }
  ].freeze

  NEW_MEMBERS = [
    { email_prefix: "enfermeira", secret_env: "DEV_NURSE_OTP_SECRET", default_secret: "ONSWG4TFOQQGC3TEEBXXE2LUNFXW4ZLF" },
    { email_prefix: "tecnico", secret_env: "DEV_TECHNICIAN_OTP_SECRET", default_secret: "ORSWG3TJMNXSA43FNZRWK4TBMRXSA43F" },
    { email_prefix: "novato", secret_env: "DEV_NEWCOMER_OTP_SECRET", default_secret: "NZXXMYLUN5QWKZDFONUW4ZLTONQXIZLS" }
  ].freeze

  PROFILES = {
    "profissional" => { professional_name: "Helena Duarte Moreira", council: "CRM" },
    "enfermeira" => { professional_name: "Carla Nogueira Prado", council: "COREN" },
    "tecnico" => { professional_name: "Rafael Teixeira Lima", council: "COREN" }
  }.freeze

  class << self
    def seed_current_city(slug:, password:, admin:)
      units = UNITS.to_h { |u| [ u[:name], HealthUnit.find_or_create_by!(name: u[:name]) { |h| h.kind = u[:kind] } ] }
      accounts = NEW_MEMBERS.map { |m| ensure_member(m, slug: slug, password: password) }
      uf = CityProfile.current&.uf.presence || "PR"
      professionals = PROFILES.keys.to_h { |prefix| [ prefix, ensure_profile(prefix, slug: slug, uf: uf, admin: admin) ] }

      ubs1, ubs2, upa = units.values_at("UBS Jardim das Flores", "UBS Vila Esperança", "UPA 24h Centro")
      medica_ubs = ensure_link(professionals["profissional"], ubs1, "225125", admin)
      medica_upa = ensure_link(professionals["profissional"], upa, "225124", admin)
      enf_ubs = ensure_link(professionals["enfermeira"], ubs1, "223505", admin)
      ensure_ended_link(professionals["enfermeira"], ubs2, "223505", admin)
      tec_upa = ensure_link(professionals["tecnico"], upa, "322205", admin)

      days = business_days
      ensure_shifts(medica_ubs, admin, days.map { |d| [ at(d, 7), at(d, 13) ] })
      ensure_shifts(medica_upa, admin, [ [ at(days.last + 1, 19), at(days.last + 2, 7) ] ])
      ensure_shifts(enf_ubs, admin, days.map { |d| [ at(d, 7), at(d, 19) ] })
      ensure_shifts(tec_upa, admin, [ [ at(Time.zone.today + 2, 7), at(Time.zone.today + 3, 7) ] ])

      {
        units: units.keys,
        accounts: accounts,
        professionals: professionals.map do |prefix, p|
          { email: "#{prefix}@#{slug}.demo", name: p.professional_name, links: p.links.active.count,
            shifts: ProfessionalShift.valid_shifts.where(professional: p).count }
        end
      }
    end

    # Os cinco próximos dias úteis (a partir de amanhã). Público: a semente da
    # agenda (módulo 17) completa a mesma semana.
    def business_days = (1..9).map { |n| Time.zone.today + n }.reject { |d| d.saturday? || d.sunday? }.first(5)

    def at(day, hour) = day.in_time_zone.change(hour: hour)

    private

    def ensure_member(member, slug:, password:)
      user = User.find_or_initialize_by(email_address: "#{member[:email_prefix]}@#{slug}.demo")
      user.password = password
      user.save!
      Membership.find_or_create_by!(user: user, role: "health_professional") { |m| m.granted_at = Time.current }
      SignatureCrew.ensure_totp(user, secret_env: member[:secret_env], default_secret: member[:default_secret])
      { email: user.email_address, role: "health_professional", otpauth_uri: SignatureCrew.otpauth_uri(user) }
    end

    def ensure_profile(prefix, slug:, uf:, admin:)
      user = User.find_by!(email_address: "#{prefix}@#{slug}.demo")
      return user.professional if user.professional

      seed = "#{slug}:#{prefix}"
      attrs = PROFILES.fetch(prefix).merge(council_state: uf, cns: Professionals::Cns.generate(seed),
                                           registration_number: (Zlib.crc32(seed) % 90_000 + 10_000).to_s)
      result = Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin)
      raise "semente: perfil de #{prefix} recusado (#{result.reason} #{result.details})" if result.failure?

      result.payload[:professional]
    end

    def ensure_link(professional, unit, cbo, admin)
      existing = professional.links.active.find_by(health_unit: unit, cbo_code: cbo)
      return existing if existing

      result = Professionals::OpenLink.call(professional: professional, health_unit_id: unit.id, cbo_code: cbo, by: admin)
      raise "semente: vínculo #{cbo} recusado (#{result.reason})" if result.failure?

      result.payload[:link]
    end

    # Histórico: o vínculo encerrado só nasce se o par nunca existiu.
    def ensure_ended_link(professional, unit, cbo, admin)
      return if professional.links.exists?(health_unit: unit, cbo_code: cbo)

      Professionals::EndLink.call(link: ensure_link(professional, unit, cbo, admin), by: admin)
    end

    def ensure_shifts(link, admin, windows)
      return if link.shifts.valid_shifts.where("starts_at > ?", Time.current).exists?

      windows.each do |starts_at, ends_at|
        result = Professionals::ScheduleShift.call(link: link, starts_at: starts_at, ends_at: ends_at, by: admin)
        raise "semente: turno recusado (#{result.reason} #{result.details})" if result.failure?
      end
    end
  end
end
