# app/services/cnes/import.rb
# Importação da base mensal do CNES pelo operador (ADR 0028; spec 2026-10-05
# §5, §8). Os municípios saem do city_profile de cada cidade ATIVA (fonte única
# do IBGE, contratos §3); cidade sem IBGE ou fora do ar é pulada e relatada,
# sem derrubar as outras. Um retrato por município encontrado no arquivo, cada
# um na sua transação: se a importação para no meio, os já gravados ficam, a
# auditoria os conta (ensure) e a falha diz quais foram (details[:imported]) e
# em qual parou (details[:failed_ibge_code]) — só a classe do erro, nunca a
# mensagem (pode carregar linha do arquivo).
# Reasons: :invalid_competence, :file_not_found, :no_city, :interrupted.
module Cnes
  module Import
    COMPETENCE = /\A\d{4}(0[1-9]|1[0-2])\z/

    module_function

    def call(competence:, path:)
      return Result.fail(:invalid_competence) unless competence.to_s.match?(COMPETENCE)

      wanted, skipped = municipalities
      return Result.fail(:no_city, details: { skipped: skipped }) if wanted.empty?

      imported = {}
      current = nil
      begin
        OfficialArchive.open(path) do |archive|
          BaseReader.read(archive, municipalities: wanted.transform_keys { |ibge| ibge[0, 6] }.to_h { |k, v| [ k, v.first ] })
                    .each do |ibge, data|
            if data[:establishments].empty?
              wanted[ibge].last.each { |slug| skipped << { slug: slug, reason: "not_in_file" } }
              next
            end

            current = ibge
            SnapshotWriter.write!(competence: competence.to_s, ibge_code: ibge, **data)
            imported[ibge] = data.transform_values(&:size)
            current = nil
          end
        end
        Result.ok(imported: imported, skipped: skipped)
      rescue OfficialArchive::NotFound => e
        Result.fail(:file_not_found, message: e.message)
      rescue StandardError => e
        Result.fail(:interrupted, message: e.class.name,
                                  details: { imported: imported, failed_ibge_code: current, skipped: skipped })
      ensure
        Platform.audit("cnes.snapshot_imported", competence: competence.to_s, ibge_codes_count: imported.size) if imported.any?
      end
    end

    # { "4106902" => ["4106902", ["curitiba"]] } e os pulados.
    def municipalities
      wanted = {}
      skipped = []
      City.active.order(:slug).each do |city|
        ibge = CityConnection.with(city) { CityProfile.current&.ibge_code }
        next skipped << { slug: city.slug, reason: "no_ibge_code" } if ibge.blank?

        (wanted[ibge] ||= [ ibge, [] ]).last << city.slug
      rescue *Maintenance::CityConnectionErrors::CLASSES
        skipped << { slug: city.slug, reason: "city_unreachable" }
      end
      [ wanted, skipped ]
    end
  end
end
