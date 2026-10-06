# lib/record_mode_crew.rb
require "digest"
require "zlib"
require "tmpdir"
require Rails.root.join("lib/sigtap_sample").to_s

# Semente de dev do módulo 16 (spec 2026-10-05 §10), sem o exportador. Dev é
# fictício mas imita o real: IBGE real (já no city_profile), modo off, SIGTAP
# reduzida ativa na competência corrente, CPF com verificador válido nos
# profissionais, credencial cadsus "simulado" (o backend de dev é simulado) e
# um retrato do CNES da competência anterior, coerente com as unidades e
# profissionais do ProfessionalCrew: as unidades ainda SEM CNES, para a tela
# mostrar propostas a confirmar; uma divergência de CBO de propósito.
# Interruptores ficam desligados: quem liga é o mantenedor. Idempotente.
class RecordModeCrew
  class << self
    def seed_platform!
      competence = Time.zone.today.strftime("%Y%m")
      return { sigtap: competence, imported: false } if TerminologyRelease.active.exists?(kind: "sigtap", version: competence)

      Dir.mktmpdir do |dir|
        result = Terminology::Import.call(kind: "sigtap", version: competence,
                                          path: SigtapSample.write_to(dir, competence: competence), by: "db:seed")
        raise "semente: SIGTAP recusada (#{result.reason} #{result.message})" if result.failure?
      end
      { sigtap: competence, imported: true }
    end

    def seed_current_city(slug:, admin:)
      ibge = CityProfile.current&.ibge_code
      raise "semente: cidade sem IBGE no city_profile" if ibge.blank?

      pros = ProfessionalCrew::PROFILES.keys.to_h do |prefix|
        [ prefix, User.find_by!(email_address: "#{prefix}@#{slug}.demo").professional ]
      end
      pros.each { |prefix, p| p.update!(cpf: cpf_for("#{slug}:#{prefix}")) if p.cpf.nil? }

      IntegrationCredential.find_or_create_by!(kind: "cadsus") do |c|
        c.secret = { "username" => "simulado", "password" => "simulado" }
        c.set_by_user = admin
        c.set_at = Time.current
      end

      competence = Time.zone.today.prev_month.strftime("%Y%m")
      cnes = ProfessionalCrew::UNITS.to_h { |u| [ u[:name], cnes_for(slug, u[:name]) ] }
      esf = ine_for(slug, "ESF")
      eap = ine_for(slug, "EAP")
      snapshot = Cnes::SnapshotWriter.write!(
        competence: competence, ibge_code: ibge,
        establishments: ProfessionalCrew::UNITS.map { |u| { cnes: cnes[u[:name]], name: u[:name].upcase, unit_type: u[:kind] == "upa" ? "73" : "02" } } +
                        [ { cnes: cnes_for(slug, "HOSPITAL"), name: "HOSPITAL MUNICIPAL", unit_type: "05" } ],
        teams: [ { ine: esf, kind: "70", cnes: cnes["UBS Jardim das Flores"], name: "ESF JARDIM DAS FLORES", active: true },
                 { ine: eap, kind: "76", cnes: cnes["UBS Vila Esperança"], name: "EAP VILA ESPERANCA", active: true } ],
        bonds: [
          bond(pros["profissional"], cnes["UBS Jardim das Flores"], esf, "225125"),
          bond(pros["profissional"], cnes["UPA 24h Centro"], nil, "225124"),
          bond(pros["enfermeira"], cnes["UBS Jardim das Flores"], esf, "223505"),
          # Divergência de propósito: o CNES diz outro CBO para o técnico.
          bond(pros["tecnico"], cnes["UPA 24h Centro"], nil, "322245")
        ]
      )
      { ibge_code: ibge, cnes_competence: competence, establishments: snapshot.establishments.count,
        teams: snapshot.teams.count, bonds: snapshot.bonds.count }
    end

    # CPF fictício com dígito verificador válido, estável pela semente.
    def cpf_for(seed)
      (0..).each do |attempt|
        base = Digest::SHA256.hexdigest("#{seed}:#{attempt}").scan(/\d/).join[0, 9].ljust(9, "1")
        next if base.chars.uniq.size == 1

        nums = base.chars.map(&:to_i)
        first = CitizenIdentity::Cpf.check_digit(nums)
        return base + first.to_s + CitizenIdentity::Cpf.check_digit(nums + [ first ]).to_s
      end
    end

    private

    def bond(professional, cnes, ine, cbo)
      { cnes: cnes, ine: ine, cbo_code: cbo, cpf: professional.cpf, cns: professional.cns }
    end

    def cnes_for(slug, name) = (Zlib.crc32("cnes:#{slug}:#{name}") % 9_000_000 + 1_000_000).to_s
    def ine_for(slug, name) = Zlib.crc32("ine:#{slug}:#{name}").to_s.rjust(10, "0")
  end
end
