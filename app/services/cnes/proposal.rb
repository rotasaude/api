# app/services/cnes/proposal.rb
require "digest"

# Propostas de casamento entre o retrato mais recente do CNES e o cadastro da
# cidade (ADR 0028; spec 2026-10-05 §5; contratos §5.2; desvio 13). Cálculo em
# memória, sem escrita: nada é aplicado sem confirmação (Cnes::Apply). O `id`
# deriva do retrato e do alvo — mudou o cadastro ou chegou retrato novo, a
# proposta antiga deixa de existir (Apply a pula como `stale`). CPF/CNS só
# saem mascarados.
module Cnes
  class Proposal
    def self.for(city) = CityConnection.with(city) { new.call }

    def call
      ibge = CityProfile.current&.ibge_code
      @snapshot = ibge && CnesSnapshot.where(ibge_code: ibge).order(competence: :desc).first
      return { snapshot: nil, proposals: [], divergences: [] } unless @snapshot

      load_data
      @proposals = []
      @divergences = []
      units
      teams
      members
      bond_divergences
      { snapshot: @snapshot, proposals: @proposals, divergences: @divergences.uniq }
    end

    private

    def load_data
      @establishments = @snapshot.establishments.to_a
      @cnes_teams = @snapshot.teams.to_a
      @bonds = @snapshot.bonds.to_a
      @units = HealthUnit.order(:name).to_a
      @unit_by_cnes = @units.select(&:cnes).index_by(&:cnes)
      @teams = HealthTeam.all.to_a
      @team_by_ine = @teams.index_by(&:ine)
      @professionals = Professional.all.to_a
      @by_cpf = @professionals.select(&:cpf).index_by(&:cpf)
      @by_cns = @professionals.index_by(&:cns)
      @members = HealthTeamMember.active.includes(:health_team, :professional).to_a
    end

    def units
      teamed = @cnes_teams.select { |t| t.active && HealthTeam::KINDS.include?(t.kind) }.map(&:cnes).to_set
      linked = []
      @establishments.each do |est|
        next if @unit_by_cnes.key?(est.cnes)

        candidate = @units.find { |u| u.cnes.nil? && !linked.include?(u.id) && normalize(u.name) == normalize(est.name) }
        cnes_side = { name: est.name, cnes: est.cnes }
        if candidate
          linked << candidate.id
          add("unit", "link", "probable", { name: candidate.name, cnes: nil }, cnes_side,
              health_unit_id: candidate.id, cnes: est.cnes)
        elsif teamed.include?(est.cnes)
          add("unit", "create", "exact", nil, cnes_side, cnes: est.cnes, name: est.name)
        end
      end
      @units.select { |u| u.active && u.cnes.nil? && !linked.include?(u.id) }.each do |u|
        diverge("unit_without_cnes", "health_unit", u.id, u.name, nil)
      end
    end

    def teams
      snapshot_by_ine = @cnes_teams.index_by(&:ine)
      @cnes_teams.each do |team|
        unit = @unit_by_cnes[team.cnes]
        next unless team.active && HealthTeam::KINDS.include?(team.kind) && unit && !@team_by_ine.key?(team.ine)

        add("team", "create", "exact", nil, { name: team.name.to_s, cnes: team.cnes, ine: team.ine },
            ine: team.ine, kind: team.kind, name: team.name, health_unit_id: unit.id)
      end
      @teams.select(&:active).each do |team|
        remote = snapshot_by_ine[team.ine]
        next if remote&.active

        detail = remote ? "Equipe inativa no CNES" : "INE ausente do CNES"
        add("team", "end", remote ? "exact" : "probable", { name: team.name.to_s, ine: team.ine },
            { name: remote&.name.to_s, ine: team.ine }, health_team_id: team.id)
        diverge("team_inactive_in_cnes", "health_team", team.id, team.name.presence || team.ine, detail)
      end
    end

    def members
      seen = Set.new
      @bonds.select(&:ine).sort_by { |b| b.cbo_code.to_s }.each do |bond|
        team = @team_by_ine[bond.ine]
        next unless team&.active

        professional, confidence = match(bond)
        next unless professional
        next unless seen.add?([ professional.id, team.id ])
        next if @members.any? { |m| m.professional_id == professional.id && m.health_team_id == team.id }

        add("member", "create", confidence, person(professional),
            { name: team.name.to_s, ine: team.ine, cbo: bond.cbo_code, cpf_masked: bond.cpf_masked, cns_masked: bond.cns_masked },
            professional_id: professional.id, health_team_id: team.id, cbo_code: bond.cbo_code)
      end
      @members.each do |member|
        next if @bonds.any? { |b| b.ine == member.health_team.ine && same_person?(b, member.professional) }

        add("member", "end", "exact", person(member.professional),
            { name: member.health_team.name.to_s, ine: member.health_team.ine, cbo: member.cbo_code },
            health_team_member_id: member.id)
      end
    end

    def bond_divergences
      ProfessionalLink.active.includes(:health_unit, :professional).group_by { |l| [ l.professional, l.health_unit ] }
                      .each do |(professional, unit), links|
        next unless unit.cnes

        here = @bonds.select { |b| b.cnes == unit.cnes && same_person?(b, professional) }
        label = professional.professional_name
        if here.empty?
          diverge("no_bond_in_cnes", "professional", professional.id, label, "Sem vínculo no CNES em #{unit.name}")
          next
        end
        local = links.map(&:cbo_code).uniq.sort
        here.map(&:cbo_code).uniq.reject { |cbo| local.include?(cbo) }.each do |cbo|
          diverge("cbo_mismatch", "professional", professional.id, label, "CNES informa CBO #{cbo}; cadastro: #{local.join(', ')}")
        end
      end
    end

    def match(bond)
      return [ @by_cpf[bond.cpf], "exact" ] if bond.cpf && @by_cpf[bond.cpf]
      return [ @by_cns[bond.cns], "probable" ] if bond.cns && @by_cns[bond.cns]

      [ nil, nil ]
    end

    def same_person?(bond, professional)
      (bond.cpf && bond.cpf == professional.cpf) || (bond.cns && bond.cns == professional.cns)
    end

    def person(p) = { name: p.professional_name, cpf_masked: p.cpf_masked, cns_masked: p.cns_masked }

    def add(kind, action, confidence, local, cnes, **target)
      id = Digest::SHA256.hexdigest([ @snapshot.id, kind, action, target.sort.to_s ].join("|"))[0, 24]
      @proposals << { id: id, kind: kind, action: action, local: local, cnes: cnes, confidence: confidence, target: target }
    end

    def diverge(kind, type, id, label, detail)
      @divergences << { kind: kind, subject: { type: type, id: id, label: label }, detail: detail }
    end

    def normalize(name) = I18n.transliterate(name.to_s).upcase.gsub(/[^A-Z0-9]+/, " ").squish
  end
end
