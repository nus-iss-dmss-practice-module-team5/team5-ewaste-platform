# Official Liquibase image with pre-bundled JDBC drivers (including MySQL)
FROM liquibase/liquibase:4.29.2

# Set working directory and copy migration changelogs and seed data for ACA Job execution
WORKDIR /liquibase/changelog
COPY . /liquibase/changelog/
