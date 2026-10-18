/* Open/close behaviour for the "Compare" popover in the report header. */
(function () {
  "use strict";

  var trigger = document.querySelector(".compare-trigger > button");
  var popover = document.getElementById("compare-popover");
  if (!trigger || !popover) { return; }

  function open() {
    popover.hidden = false;
    trigger.setAttribute("aria-expanded", "true");
  }

  function close() {
    popover.hidden = true;
    trigger.setAttribute("aria-expanded", "false");
  }

  trigger.addEventListener("click", function () {
    if (popover.hidden) { open(); } else { close(); }
  });

  document.addEventListener("click", function (event) {
    if (!popover.hidden && !popover.contains(event.target) && event.target !== trigger) {
      close();
    }
  });

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape" && !popover.hidden) { close(); }
  });
})();
