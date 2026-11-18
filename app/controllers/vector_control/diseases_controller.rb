# GET /vector_control/diseases (módulo 35a; Q38): os rótulos das doenças de
# block_diseases e do bloqueio de transmissão. `items` = a lista da cidade do
# módulo 25 (Surveillance::Diseases.all, a mesma do /surveillance/diseases e
# na mesma ordem), só código e nome; `groups` = Catalog::DISEASE_GROUP_LABELS.
# A lista (plataforma em vigor + locais ativas) não depende do interruptor
# surveillance: o gate é só o do 35a, no BaseController. Só a coordenação e o
# municipal_admin; os outros (ACE, TACS, vector_lab, profissional) → 403
# missing_role. Só rótulo, sem dado de pessoa: sem trilha.
module VectorControl
  class DiseasesController < BaseController
    def index
      user = Current.user
      return forbid unless Access.coordinator?(user) || Access.role?(user, "municipal_admin")
      return unless query_only!

      render json: Json.diseases(::Surveillance::Diseases.all)
    end
  end
end
