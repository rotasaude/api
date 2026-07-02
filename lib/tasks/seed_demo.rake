namespace :db do
  namespace :seed do
    desc "Load the dashboard demo dataset (idempotent)"
    task demo: :environment do
      load Rails.root.join("db/seeds/dashboard_demo.rb")
    end
  end
end
