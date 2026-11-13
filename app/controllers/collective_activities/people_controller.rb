# POST /collective_activities/people/{lookup,duplicates} (contrato §5; Q8): as
# buscas de pessoa do participante (FieldPersonSearch), para quem registra
# atividade em alguma equipe (CBO da Tabela 5); os outros recebem 403
# cbo_not_allowed. Trilha access "collective_activities".
module CollectiveActivities
  class PeopleController < BaseController
    include FieldPersonSearch

    private

    def person_registrar? = Access.registers_somewhere?(Current.user)
    def person_trail = Trail
  end
end
