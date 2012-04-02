desc 'Start the application'
task :start do
  system "bundle exec rackup config.ru -p 8080"
end
