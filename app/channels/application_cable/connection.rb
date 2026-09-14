module ApplicationCable
  # R45: sem uso hoje — não há config/cable.yml nem mount do Action Cable.
  # Atenção se for religado: `Session.find_by` abaixo roda SEM cidade
  # selecionada (Session é dado da cidade; fora de CityConnection.with o
  # CityRecord cai no shard bootstrap, sem tabelas, e levanta
  # PG::UndefinedTable). Seria preciso resolver a cidade pelo host antes, como
  # CityResolution faz nos controllers. O Plano 6 decide entre isso e remover
  # a superfície; não deletar aqui.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      set_current_user || reject_unauthorized_connection
    end

    private
      def set_current_user
        if session = Session.find_by(id: cookies.signed[:session_id])
          self.current_user = session.user
        end
      end
  end
end
