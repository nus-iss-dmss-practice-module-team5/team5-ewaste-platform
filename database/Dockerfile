# Liquibase Community 5.x does not bundle database drivers by default.
# Install the MySQL driver explicitly and pin the image for reproducible CI.
FROM liquibase/liquibase:5.0.3

RUN lpm add mysql --global

# Set working directory and copy migration changelogs and seed data for ACA Job execution
WORKDIR /liquibase/changelog
COPY . /liquibase/changelog/
