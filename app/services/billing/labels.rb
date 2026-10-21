# Nome SIGTAP do procedimento na release usada na crítica (ou na última
# ativa até a competência; sem release, o próprio código).
module Billing
  module Labels
    module_function

    def procedure(code, competence)
      release = Terminology::Sigtap.release_for(competence)
      (release && SigtapProcedure.where(release_id: release.id, code: code).pick(:name)) || code
    end
  end
end
