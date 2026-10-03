#include <kano_unattended.hpp>
#include <cstdio>

int main() {
    kano::infra::ConfigureUnattendedExecution();
    std::puts("Installed unattended header and target passed.");
    return 0;
}
