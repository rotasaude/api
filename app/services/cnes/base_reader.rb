# app/services/cnes/base_reader.rb
# Lê a base mensal em fluxo e devolve, por município de interesse, o retrato
# pronto para Cnes::SnapshotWriter (ADR 0028; spec 2026-10-05 §5). Cinco
# passadas, cada uma filtrando pelo que a anterior achou; só os profissionais
# com vínculo num estabelecimento de interesse têm CPF/CNS lidos. Vínculo
# desligado não entra; equipe desativada entra com active: false.
module Cnes
  module BaseReader
    module_function

    def read(archive, municipalities:)
      layout = BaseLayout
      units = {}
      rows(archive, :establishments) do |r|
        ibge = municipalities[r[layout::ESTABLISHMENT[:municipality]].to_s[0, 6]]
        cnes = r[layout::ESTABLISHMENT[:cnes]].to_s.rjust(7, "0")
        next unless ibge && cnes.match?(/\A\d{7}\z/)

        units[r[layout::ESTABLISHMENT[:unit_id]]] = { ibge: ibge, cnes: cnes, name: r[layout::ESTABLISHMENT[:name]].to_s,
                                                      unit_type: r[layout::ESTABLISHMENT[:unit_type]] }
      end

      teams = []
      team_keys = {}
      rows(archive, :teams) do |r|
        unit = units[r[layout::TEAM[:unit_id]]] or next
        ine = r[layout::TEAM[:ine]].to_s.rjust(10, "0")
        next unless ine.match?(/\A\d{10}\z/)

        team_keys[r.values_at(*layout::TEAM.values_at(:municipality, :area, :seq))] = ine
        teams << { ibge: unit[:ibge], ine: ine, kind: r[layout::TEAM[:kind]].to_s, cnes: unit[:cnes],
                   name: r[layout::TEAM[:name]], active: r[layout::TEAM[:deactivated_on]].blank? }
      end

      bonds = []
      rows(archive, :team_bonds) do |r|
        unit = units[r[layout::TEAM_BOND[:unit_id]]] or next
        next if r[layout::TEAM_BOND[:left_on]].present?

        ine = team_keys[r.values_at(*layout::TEAM_BOND.values_at(:municipality, :area, :seq))] or next
        bonds << { ibge: unit[:ibge], cnes: unit[:cnes], ine: ine, cbo_code: r[layout::TEAM_BOND[:cbo]],
                   professional_id: r[layout::TEAM_BOND[:professional_id]] }
      end
      rows(archive, :unit_bonds) do |r|
        unit = units[r[layout::UNIT_BOND[:unit_id]]] or next
        bonds << { ibge: unit[:ibge], cnes: unit[:cnes], ine: nil, cbo_code: r[layout::UNIT_BOND[:cbo]],
                   professional_id: r[layout::UNIT_BOND[:professional_id]] }
      end
      bonds = bonds.select { |b| b[:cbo_code].to_s.match?(/\A\d{6}\z/) }.uniq

      wanted = bonds.to_set { |b| b[:professional_id] }
      people = {}
      rows(archive, :professionals) do |r|
        id = r[layout::PROFESSIONAL[:professional_id]]
        next unless wanted.include?(id)

        cns = r[layout::PROFESSIONAL[:cns]].to_s
        people[id] = { cpf: CitizenIdentity::Cpf.normalize(r[layout::PROFESSIONAL[:cpf]]),
                       cns: Professionals::Cns.valid?(cns) ? cns : nil }
      end

      municipalities.values.uniq.to_h do |ibge|
        establishments = units.values.select { |u| u[:ibge] == ibge }.map { |u| u.slice(:cnes, :name, :unit_type) }
        [ ibge, {
          establishments: establishments,
          teams: teams.select { |t| t[:ibge] == ibge }.map { |t| t.except(:ibge) },
          bonds: bonds.select { |b| b[:ibge] == ibge }.map do |b|
            person = people.fetch(b[:professional_id], {})
            { cnes: b[:cnes], ine: b[:ine], cbo_code: b[:cbo_code], cpf: person[:cpf], cns: person[:cns] }
          end
        } ]
      end
    end

    def rows(archive, file, &block)
      archive.each_row(BaseLayout::FILES.fetch(file), encoding: BaseLayout::ENCODING, &block)
    end
  end
end
