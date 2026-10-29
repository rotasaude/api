require "tmpdir"
require_relative "sigtap_sample"

# Terminologias das sementes de dev (só dev; quem chama guarda o ambiente).
# Duas operações compartilhadas pelos crews, cada uma com o guarda de release
# real: uma SIGTAP ou CID-10 real ativa nunca é tocada.
module DevTerminology
  module_function

  # Uma release SIGTAP ativa maior que o recorte de dev é real (de qualquer competência).
  def real_sigtap_active?
    TerminologyRelease.active.where(kind: "sigtap").pluck(:id).any? do |id|
      SigtapProcedure.where(release_id: id).count > SigtapSample::PROCEDURES.size
    end
  end

  # Garante, em cada competência, a release SIGTAP ativa com instrumento de
  # registro para todos os `codes`; na que falta, republica o recorte de dev
  # (SigtapSample). label: o prefixo da recusa ("semente X: SIGTAP").
  # -> :real_sigtap | :republished | :complete
  def ensure_sigtap!(codes:, competences:, label:)
    return :real_sigtap if real_sigtap_active?

    imported = competences.select do |competence|
      release = TerminologyRelease.active.find_by(kind: "sigtap", version: competence)
      next false if release && SigtapProcedureInstrument.where(release_id: release.id, procedure_code: codes)
                                                         .distinct.count(:procedure_code) == codes.size

      Dir.mktmpdir do |dir|
        result = Terminology::Import.call(kind: "sigtap", version: competence, path: SigtapSample.write_to(dir, competence: competence),
                                          by: "db:seed")
        raise "#{label} recusada (#{result.reason} #{result.message})" if result.failure?
      end
      true
    end
    imported.any? ? :republished : :complete
  end

  # Soma `codes` ({ código => [descrição, restrição de sexo] }) à CID-10 ativa
  # quando ela é o recorte de dev (versão "dev-*"): republica como `version`
  # os códigos que ela já tem (que prevalecem) mais os que faltam.
  # -> :complete (todos já existem) | :real_cid10 (release real ou nenhuma) | :republished
  def add_cid10!(codes:, version:, label:)
    return :complete if codes.keys.all? { |code| ClinicalTerms.find("cid10", code) }

    active = ClinicalTerms.release("cid10")
    return :real_cid10 unless active&.version.to_s.start_with?("dev-")

    current = Cid10Code.where(release_id: active.id).pluck(:code, :description, :sex_restriction)
                       .to_h { |code, description, sex| [ code, [ description, sex ] ] }
    Dir.mktmpdir do |dir|
      write_cid10(Pathname(dir), codes.merge(current))
      result = Terminology::Import.call(kind: "cid10", version: version, path: dir, by: "db:seed")
      raise "#{label} recusada (#{result.reason} #{result.message})" if result.failure?
    end
    :republished
  end

  def write_cid10(dir, codes)
    categories, subcategories = codes.partition { |code, _| code.length == 3 }
    dir.join("CID-10-CATEGORIAS.CSV").binwrite(("CAT;DESCRICAO\n" + categories.map { |c, (d, _)| "#{c};#{d}" }.join("\n") + "\n").encode("ISO-8859-1"))
    dir.join("CID-10-SUBCATEGORIAS.CSV").binwrite(("SUBCAT;DESCRICAO;RESTRSEXO\n" +
      subcategories.map { |c, (d, sex)| "#{c};#{d};#{sex}" }.join("\n") + "\n").encode("ISO-8859-1"))
  end
  private_class_method :write_cid10
end
