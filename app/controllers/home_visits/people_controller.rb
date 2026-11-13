# POST /home_visits/people/{lookup,duplicates} (contrato §5; Q8): as buscas de
# pessoa da visita (FieldPersonSearch), para quem registra visita em alguma
# equipe (Tabela 7 em equipe ativa 70/76); o enfermeiro e o médico, que só
# leem, recebem 403 cbo_not_allowed. Trilha access "home_visits".
module HomeVisits
  class PeopleController < BaseController
    include FieldPersonSearch

    private

    def person_registrar? = Access.registers_somewhere?(Current.user)
    def person_trail = Trail
  end
end
